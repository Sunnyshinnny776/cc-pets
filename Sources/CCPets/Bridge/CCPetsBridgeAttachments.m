#import "CCPetsBridgeAttachments.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsBridge.h"
#import "CCPetsL10n.h"
#import <fcntl.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>
#import <time.h>

const NSUInteger CCBridgeAttachmentCountLimit = 8;
const NSUInteger CCBridgeAttachmentBytesLimit = 32 * 1024 * 1024;

BOOL CCBridgeSlackFileIDValid(id value) {
    return [value isKindOfClass:NSString.class] && [value rangeOfString:@"^F[A-Z0-9]{1,63}\\z" options:NSRegularExpressionSearch].location != NSNotFound;
}

NSString *CCBridgeAttachmentDay(NSTimeInterval time) {
    time_t timestamp = (time_t)time;
    struct tm local;
    char day[11];
    if (!localtime_r(&timestamp, &local) || !strftime(day, sizeof(day), "%Y-%m-%d", &local)) return nil;
    return @(day);
}

static BOOL ValidDay(NSString *value) {
    return [value isKindOfClass:NSString.class] &&
        [value rangeOfString:@"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\\z" options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL DownloadMessageID(NSString *value) {
    return [value isKindOfClass:NSString.class] &&
        [value rangeOfString:@"^s[0-9a-f]{40}\\z" options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL ValidFilename(NSString *filename) {
    return [filename isKindOfClass:NSString.class] && filename.length &&
        [filename lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= NAME_MAX &&
        [filename isEqual:filename.lastPathComponent] && ![filename isEqual:@"."] && ![filename isEqual:@".."] &&
        [filename rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL OwnedDirectory(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid();
}

static NSString *DownloadsRoot(void) {
    return [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"var/attachments"];
}

NSString *CCBridgeDownloadedAttachmentPath(NSString *day, NSString *mid, NSString *fileID, NSString *filename) {
    if (!ValidDay(day) || !DownloadMessageID(mid) || !CCBridgeSlackFileIDValid(fileID) || !ValidFilename(filename)) return nil;
    NSString *folder = CCBridgeHomeDirectory();
    int parent = open(folder.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent < 0) return nil;
    @try {
        for (NSString *component in @[@"var", @"attachments", day, mid, fileID]) {
            const char *name = component.fileSystemRepresentation;
            if (mkdirat(parent, name, 0700) != 0 && errno != EEXIST) return nil;
            int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) return nil;
            close(parent);
            parent = child;
            struct stat st;
            if (fstat(child, &st) != 0 || st.st_uid != getuid() ||
                ((st.st_mode & 0777) != 0700 && fchmod(child, 0700) != 0)) return nil;
            folder = [folder stringByAppendingPathComponent:component];
        }
    } @finally { close(parent); }
    return [folder stringByAppendingPathComponent:filename];
}

static void PruneMessageFolders(NSString *parent, long long now, BOOL dated) {
    if (!OwnedDirectory(parent)) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *mid in [fm contentsOfDirectoryAtPath:parent error:nil]) {
        BOOL managed = dated ? DownloadMessageID(mid) :
            [mid rangeOfString:@"^[a-z0-9]+\\z" options:NSRegularExpressionSearch].location != NSNotFound;
        if (!managed) continue;
        NSString *folder = [parent stringByAppendingPathComponent:mid];
        struct stat st;
        if (lstat(folder.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid() &&
            now - (long long)st.st_mtime * 1000 > 2 * CCBridgeMessageTTL && !CCBridgeReadReceipt(mid)) {
            [fm removeItemAtPath:folder error:nil];
        }
    }
}

void CCBridgePruneAttachmentFiles(long long now) {
    PruneMessageFolders([CCBridgeStateDirectory() stringByAppendingPathComponent:@"attachments"], now, NO);
    NSString *root = DownloadsRoot();
    if (!OwnedDirectory(root.stringByDeletingLastPathComponent) || !OwnedDirectory(root)) return;
    NSString *cutoffDay = CCBridgeAttachmentDay((now - 2 * CCBridgeMessageTTL) / 1000.0);
    for (NSString *day in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        if (!ValidDay(day)) continue;
        NSString *folder = [root stringByAppendingPathComponent:day];
        PruneMessageFolders(folder, now, YES);
        if ([day compare:cutoffDay] != NSOrderedDescending && OwnedDirectory(folder)) rmdir(folder.fileSystemRepresentation); // empty days only
    }
}

BOOL CCBridgeWriteAttachment(NSData *data, NSString *path) {
    NSString *folder = path.stringByDeletingLastPathComponent;
    NSString *pattern = [folder stringByAppendingPathComponent:@".partial.XXXXXX"];
    char *temporary = strdup(pattern.fileSystemRepresentation);
    if (!temporary) return NO;
    int fd = mkstemp(temporary); // 0600 from creation, in the destination directory.
    BOOL saved = NO;
    if (fd >= 0) {
        const unsigned char *bytes = data.bytes;
        NSUInteger written = 0;
        while (written < data.length) {
            ssize_t n = write(fd, bytes + written, data.length - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            written += (NSUInteger)n;
        }
        saved = close(fd) == 0 && written == data.length && rename(temporary, path.fileSystemRepresentation) == 0;
        if (!saved) unlink(temporary);
    }
    free(temporary);
    return saved;
}

static BOOL SenderCanShare(int fd, NSDictionary *sender) {
    char buffer[PATH_MAX], root[PATH_MAX];
    if (fcntl(fd, F_GETPATH, buffer) < 0) return NO;
    NSString *path = @(buffer);
    NSString *messageDir = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *parent = messageDir.stringByDeletingLastPathComponent;
    NSString *legacy = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"attachments"];
    BOOL inbound = DownloadMessageID(messageDir.lastPathComponent) && CCBridgeSlackFileIDValid(path.stringByDeletingLastPathComponent.lastPathComponent);
    BOOL archived = inbound && OwnedDirectory(legacy) && realpath(legacy.fileSystemRepresentation, root) && [parent isEqual:@(root)];
    if (inbound && !archived && ValidDay(parent.lastPathComponent)) {
        NSString *downloads = DownloadsRoot();
        archived = OwnedDirectory(downloads.stringByDeletingLastPathComponent) && OwnedDirectory(downloads) &&
            realpath(downloads.fileSystemRepresentation, root) && [parent.stringByDeletingLastPathComponent isEqual:@(root)];
    }
    // Check the exact receipt before the general Bridge-home exclusion.
    if (archived) return [CCBridgeReadReceipt(messageDir.lastPathComponent)[@"to"][@"session"] isEqual:sender[@"session"]];
    if (realpath(CCBridgeHomeDirectory().fileSystemRepresentation, root) && [path hasPrefix:[@(root) stringByAppendingString:@"/"]]) return NO;
    if (realpath(CCBridgeStateDirectory().fileSystemRepresentation, root) && [path hasPrefix:[@(root) stringByAppendingString:@"/"]]) return NO;
    NSString *cwd = sender[@"cwd"];
    if (!cwd.isAbsolutePath || !realpath(cwd.fileSystemRepresentation, root)) return NO;
    return [@(root) isEqual:@"/"] || [path hasPrefix:[@(root) stringByAppendingString:@"/"]];
}

NSArray<NSString *> *CCBridgeSnapshotAttachments(id paths, NSDictionary *sender, NSString *mid, NSString **error) {
    if (!paths) return @[];
    if (![paths isKindOfClass:NSArray.class] || [paths count] > CCBridgeAttachmentCountLimit) {
        *error = L(@"Provide up to eight attachment file paths.");
        return nil;
    }
    NSString *cwd = sender[@"cwd"];
    NSMutableArray *copies = [NSMutableArray array];
    NSUInteger remaining = CCBridgeAttachmentBytesLimit;
    for (id input in paths) {
        NSString *path = [input isKindOfClass:NSString.class] ? input : nil;
        if (!path.length || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            (!path.isAbsolutePath && !cwd.isAbsolutePath)) {
            *error = L(@"Invalid attachment path.");
            return nil;
        }
        NSString *source = path.isAbsolutePath ? path : [cwd stringByAppendingPathComponent:path];
        // Resolve relative to the sender, never to the adapter's working directory.
        // O_NONBLOCK lets us reject FIFOs without blocking the MCP process.
        int fd = open(source.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) {
            *error = [NSString stringWithFormat:L(@"Cannot read attachment: %@"), path.lastPathComponent];
            return nil;
        }
        @try {
            if (!SenderCanShare(fd, sender)) {
                *error = L(@"Choose a file in the sending session’s working directory or its received attachments.");
                return nil;
            }
            struct stat st;
            if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
                (unsigned long long)st.st_size > remaining) {
                *error = L(@"Attachments must be regular files totaling at most 32 MiB.");
                return nil;
            }
            if (!ValidFilename(path.lastPathComponent) || !CCBridgeSafeSessionId(mid)) { *error = L(@"Invalid attachment name."); return nil; }
            NSString *folder = CCBridgeSubdirectory(@[@"attachments", mid, @(copies.count).stringValue]);
            NSString *copy = [folder stringByAppendingPathComponent:path.lastPathComponent];
            // Bound the read even if the source grows after fstat.
            NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)st.st_size];
            unsigned char buffer[65536];
            while (data.length <= (NSUInteger)st.st_size) {
                ssize_t count = read(fd, buffer, MIN(sizeof(buffer), (NSUInteger)st.st_size + 1 - data.length));
                if (count < 0 && errno == EINTR) continue;
                if (count < 0) { *error = L(@"Could not read attachment data."); return nil; }
                if (count == 0) break;
                [data appendBytes:buffer length:(NSUInteger)count];
            }
            struct stat final;
            if (fstat(fd, &final) != 0 || data.length != (NSUInteger)st.st_size || st.st_size != final.st_size ||
                st.st_mtimespec.tv_sec != final.st_mtimespec.tv_sec || st.st_mtimespec.tv_nsec != final.st_mtimespec.tv_nsec ||
                !CCBridgeWriteAttachment(data, copy)) {
                *error = L(@"Attachment changed or could not be saved.");
                return nil;
            }
            remaining -= data.length;
            [copies addObject:copy];
        } @finally { close(fd); }
    }
    return copies;
}
