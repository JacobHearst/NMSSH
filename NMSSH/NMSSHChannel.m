#import "NMSSH.h"

#import "libssh2.h"

@interface NMSSHChannel () {
    LIBSSH2_CHANNEL *channel;
}
@end

@implementation NMSSHChannel

// -----------------------------------------------------------------------------
// PUBLIC SETUP API
// -----------------------------------------------------------------------------

- (id)initWithSession:(NMSSHSession *)session {
    if ((self = [super init])) {
        _session = session;
        _requestPty = NO;
        _ptyTerminalType = NMSSHChannelPtyTerminalVanilla;

        // Make sure we were provided a valid session
        if (![_session isKindOfClass:[NMSSHSession class]]) {
            return nil;
        }
    }

    return self;
}

// -----------------------------------------------------------------------------
// PUBLIC SHELL EXECUTION API
// -----------------------------------------------------------------------------

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error {
    return [self execute:command error:error timeout:[NSNumber numberWithDouble:0]];
}

- (NSString *)execute:(NSString *)command error:(NSError *__autoreleasing *)error timeout:(NSNumber *)timeout {
    NMSSHLogInfo(@"NMSSH: Exec command %@", command);

    _lastResponse = nil;

    // Open up the channel
    while( (channel = libssh2_channel_open_session([_session rawSession])) == NULL &&
		  libssh2_session_last_error([_session rawSession],NULL,NULL,0) ==
		  LIBSSH2_ERROR_EAGAIN ) {
        waitsocket([_session sock], [_session rawSession]);
    }
    if(channel == NULL){
        NMSSHLogError(@"NMSSH: Unable to open a session");
        return nil;
    }

    // In case of error...
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:command
                                                                       forKey:@"command"];

    // If requested, try to allocate a pty
    int rc = 0;

    if (self.requestPty) {
        rc = libssh2_channel_request_pty(channel, [self getTerminalNameForType:self.ptyTerminalType]);
        if (rc) {
            if (error) {
                *error = [NSError errorWithDomain:@"NMSSH"
                                             code:NMSSHChannelRequestPtyError
                                         userInfo:userInfo];
            }

            NMSSHLogError(@"NMSSH: Error requesting pseudo terminal");
            [self close];
            return nil;
        }
    }

    // Try executing command
    while ((rc = libssh2_channel_exec(channel, [command UTF8String])) == LIBSSH2_ERROR_EAGAIN) {
        waitsocket([_session sock], [_session rawSession]);
    }

    libssh2_channel_wait_closed(channel);

    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"NMSSH"
                                         code:NMSSHChannelExecutionError
                                     userInfo:userInfo];
        }

        NMSSHLogError(@"NMSSH: Error executing command");
        [self close];
        return nil;
    }

    // Set the timeout for blocking session
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent() + [timeout doubleValue];
    if ([timeout longValue] >= 0) {
        libssh2_session_set_timeout([_session rawSession], [timeout longValue] * 1000);
    }

    // Fetch response from output buffer
    for (;;) {
        long rc;
        char buffer[0x4000];
        char errorBuffer[0x4000];

        do {
            rc = libssh2_channel_read(channel, buffer, (ssize_t)sizeof(buffer));

            // Store all errors that might occur
            if (libssh2_channel_get_exit_status(channel)) {
                if (error) {
                    libssh2_channel_read_stderr(channel, errorBuffer,
                                                (ssize_t)sizeof(errorBuffer));

                    NSString *desc = [NSString stringWithUTF8String:errorBuffer];
                    if (!desc) {
                        desc = @"An unspecified error occurred";
                    }

                    [userInfo setObject:desc forKey:NSLocalizedDescriptionKey];

                    *error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionError
                                             userInfo:userInfo];
                    return nil;
                }
            }

            if (rc == 0) {
                _lastResponse = [NSString stringWithFormat:@"%s", buffer];
                [self close];
                return _lastResponse;
            }

            // Check if the connection timed out
            if ([timeout longValue] > 0 && time < CFAbsoluteTimeGetCurrent()) {
                if (error) {
                    NSString *desc = @"Connection timed out";

                    [userInfo setObject:desc forKey:NSLocalizedDescriptionKey];

                    *error = [NSError errorWithDomain:@"NMSSH"
                                                 code:NMSSHChannelExecutionTimeout
                                             userInfo:userInfo];
                }
                [self close];
                return nil;
            }
        }
        while (rc > 0);

        // This is due to blocking that would occur otherwise so we loop on this condition
        if( rc == LIBSSH2_ERROR_EAGAIN ) {
            waitsocket([_session sock], [_session rawSession]);
        } else {
            break;
        }
    }

    // If we've got this far, it means fetching execution response failed
    if (error) {
        *error = [NSError errorWithDomain:@"NMSSH"
                                     code:NMSSHChannelExecutionResponseError
                                 userInfo:userInfo];
    }

    NMSSHLogError(@"NMSSH: Error fetching response from command");
    [self close];
    return nil;
}

// -----------------------------------------------------------------------------
// PUBLIC SCP API
// -----------------------------------------------------------------------------

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath {
    localPath = [localPath stringByExpandingTildeInPath];

    // Inherit file name if to: contains a directory
    if ([remotePath hasSuffix:@"/"]) {
        remotePath = [remotePath stringByAppendingString:
                     [[localPath componentsSeparatedByString:@"/"] lastObject]];
    }

    // Read local file
    FILE *local = fopen([localPath UTF8String], "rb");
    if (!local) {
        NMSSHLogError(@"NMSSH: Can't read local file");
        return NO;
    }

    // Try to send a file via SCP.
    struct stat fileinfo;
    stat([localPath UTF8String], &fileinfo);
    channel = libssh2_scp_send([_session rawSession], [remotePath UTF8String],
                               fileinfo.st_mode & 0644,
                               (unsigned long)fileinfo.st_size);

    if (!channel) {
        NMSSHLogError(@"NMSSH: Unable to open SCP session");
        return NO;
    }

    // Wait for file transfer to finish
    char mem[1024];
    size_t nread;
    char *ptr;
    do {
        nread = fread(mem, 1, sizeof(mem), local);
        if (nread <= 0) {
            break; // End of file
        }
        ptr = mem;

        do {
            // Write the same data over and over, until error or completion
            long rc = libssh2_channel_write(channel, ptr, nread);

            if (rc < 0) {
                NMSSHLogError(@"NMSSH: Failed writing file");
                [self close];
                return NO;
            }
            else {
                // rc indicates how many bytes were written this time
                ptr += rc;
                nread -= rc;
            }
        } while (nread);
    } while (1);

    // Send EOF and clean up
    libssh2_channel_send_eof(channel);
    libssh2_channel_wait_eof(channel);
    libssh2_channel_wait_closed(channel);
    [self close];

    return YES;
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath {
    localPath = [localPath stringByExpandingTildeInPath];

    // Inherit file name if to: contains a directory
    if ([localPath hasSuffix:@"/"]) {
        localPath = [localPath stringByAppendingString:
                    [[remotePath componentsSeparatedByString:@"/"] lastObject]];
    }

    // Request a file via SCP
    struct stat fileinfo;
    channel = libssh2_scp_recv([_session rawSession], [remotePath UTF8String],
                               &fileinfo);

    if (!channel) {
        NMSSHLogError(@"NMSSH: Unable to open SCP session");
        return NO;
    }

    // Open local file in order to write to it
    int localFile = open([localPath UTF8String], O_WRONLY|O_CREAT, 0644);

    // Save data to local file
    off_t got = 0;
    while (got < fileinfo.st_size) {
        char mem[1024];
        long long amount = sizeof(mem);

        if ((fileinfo.st_size - got) < amount) {
            amount = fileinfo.st_size - got;
        }

        ssize_t rc = libssh2_channel_read(channel, mem, amount);

        if (rc > 0) {
            write(localFile, mem, rc);
        }
        else if (rc < 0) {
            NMSSHLogError(@"NMSSH: Failed to read SCP data");
            close(localFile);
            [self close];
            return NO;
        }

        got += rc;
    }

    close(localFile);
    [self close];
    return YES;
}

// -----------------------------------------------------------------------------
// PRIVATE HELPER METHODS
// -----------------------------------------------------------------------------

- (void)close {
    if (channel) {
        libssh2_channel_close(channel);
        libssh2_channel_free(channel);
        channel = nil;
    }
}

- (const char*)getTerminalNameForType:(unsigned long)terminalType {
    switch (terminalType) {
        case NMSSHChannelPtyTerminalVanilla:
            return "vanilla";

        case NMSSHChannelPtyTerminalVT102:
            return "vt102";

        case NMSSHChannelPtyTerminalAnsi:
            return "ansi";
    }

    // catch invalid values
    return "vanilla";
}

static int waitsocket(int socket_fd, LIBSSH2_SESSION *session) {
    struct timeval timeout;

    fd_set fd;
    fd_set *writefd = NULL;
    fd_set *readfd = NULL;

    int rc;
    int dir;
    timeout.tv_sec = 0;
    timeout.tv_usec = 500000;

    FD_ZERO(&fd);
    FD_SET(socket_fd, &fd);

    // Now make sure we wait in the correct direction
    dir = libssh2_session_block_directions(session);

    if (dir & LIBSSH2_SESSION_BLOCK_INBOUND) {
        readfd = &fd;
    }

    if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) {
        writefd = &fd;
    }

    rc = select(socket_fd + 1, readfd, writefd, NULL, &timeout);

    return rc;
}

@end
