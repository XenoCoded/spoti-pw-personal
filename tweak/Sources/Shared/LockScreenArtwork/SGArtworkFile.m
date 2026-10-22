#import <AVFoundation/AVFoundation.h>
#include <string.h>
#import "Core/SGCore.h"
#import "SGArtworkFile.h"

static const unsigned long long kCap = 120 * 1024 * 1024;   // an Apple Music cover is about 8 MB
// A clip this close to the shape asked for is handed over untouched rather than re-encoded.
static const CGFloat kAspectSlack = 0.02;

static dispatch_queue_t queue(void) {
    static dispatch_queue_t shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = dispatch_queue_create("com.spotifyglass.lockartwork", DISPATCH_QUEUE_SERIAL); });
    return shared;
}

static NSURL *directory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"spoti.pw/LockArtwork"]];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

static NSURL *fileFor(NSString *name) {
    return [directory() URLByAppendingPathComponent:name];
}

// Kept alive by its use, so the file the lock screen is playing is the last one to go.
static void touch(NSURL *file) {
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:file.path error:nil];
}

static void prune(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSURLResourceKey> *wanted = @[NSURLContentModificationDateKey, NSURLFileSizeKey];
    NSArray<NSURL *> *kept = [files contentsOfDirectoryAtURL:directory() includingPropertiesForKeys:wanted options:0 error:nil];
    unsigned long long total = 0;
    for (NSURL *file in kept) total += [[file resourceValuesForKeys:wanted error:nil][NSURLFileSizeKey] unsignedLongLongValue];
    if (total <= kCap) return;
    NSArray<NSURL *> *oldest = [kept sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *left = [a resourceValuesForKeys:wanted error:nil][NSURLContentModificationDateKey];
        NSDate *right = [b resourceValuesForKeys:wanted error:nil][NSURLContentModificationDateKey];
        return [left ?: NSDate.distantPast compare:right ?: NSDate.distantPast];
    }];
    for (NSURL *file in oldest) {
        if (total <= kCap) break;
        // Subtract only what was actually removed (Batch 93), the
        // clip cache's prune had the same habit.
        unsigned long long size = [[file resourceValuesForKeys:wanted error:nil][NSURLFileSizeKey] unsignedLongLongValue];
        if ([files removeItemAtURL:file error:nil]) total -= size;
    }
    SGLog(@"lock artwork: cache pruned to %llu KB", total / 1024);
}

static NSURLSessionDownloadTask *sg_task;

void SGArtworkCancelFetch(void) {
    NSURLSessionDownloadTask *task = sg_task;
    sg_task = nil;
    [task cancel];
}

// Completions land on the main queue whichever path produced them
// (Batch 90): the immediate answers used to fire on the caller's
// thread, a failure on the session's queue and a success on the file
// queue, and the one consumer had to tolerate all three.
static void finish(void (^done)(NSURL *file, NSString *note), NSURL *file, NSString *note) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(file, note); });
}

void SGArtworkFetch(NSString *identifier, NSString *address, void (^done)(NSURL *file, NSString *note)) {
    SGArtworkCancelFetch();
    NSURL *remote = address.length ? [NSURL URLWithString:address] : nil;
    if (!remote) {
        finish(done, nil, @"no address");
        return;
    }
    NSURL *local = fileFor([identifier stringByAppendingPathExtension:@"mp4"]);
    if ([NSFileManager.defaultManager fileExistsAtPath:local.path]) {
        dispatch_async(queue(), ^{ touch(local); });
        finish(done, local, @"cached");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remote];
    // Low Data Mode marks the path constrained; the download then fails rather than spending the data.
    request.allowsConstrainedNetworkAccess = NO;
    sg_task = [NSURLSession.sharedSession downloadTaskWithRequest:request completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        if (!temporary) {
            finish(done, nil, [NSString stringWithFormat:@"download failed: %@", error.localizedDescription]);
            return;
        }
        long long length = response.expectedContentLength;
        // What lands here is trusted by existence alone from then on
        // (Batch 93): an HTTP error page or a sign-in wall used to be
        // moved in as the "video" and poison the identifier for good.
        // An MP4 carries ftyp at bytes 4-8; anything else never moves.
        if ([response isKindOfClass:NSHTTPURLResponse.class]
            && ((NSHTTPURLResponse *)response).statusCode != 200) {
            finish(done, nil, [NSString stringWithFormat:@"download failed: HTTP %ld",
                                (long)((NSHTTPURLResponse *)response).statusCode]);
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:temporary error:nil];
        NSData *head = [handle readDataOfLength:8];
        [handle closeFile];
        BOOL isVideo = head.length >= 8
            && memcmp((const char *)head.bytes + 4, "ftyp", 4) == 0;
        if (!isVideo) {
            finish(done, nil, @"download was not a video");
            return;
        }
        dispatch_async(queue(), ^{
            NSError *move = nil;
            [NSFileManager.defaultManager removeItemAtURL:local error:nil];
            BOOL moved = [NSFileManager.defaultManager moveItemAtURL:temporary toURL:local error:&move];
            if (moved) prune();
            finish(done, moved ? local : nil, moved ? [NSString stringWithFormat:@"downloaded %lld KB", length / 1024]
                                            : [NSString stringWithFormat:@"not kept: %@", move.localizedDescription]);
        });
    }];
    [sg_task resume];
}

// The size the clip is played at, its rotation applied, and the transform that puts its top left at
// the origin.
static CGSize shownSize(AVAssetTrack *track, CGAffineTransform *upright) {
    CGRect shown = CGRectApplyAffineTransform(CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height),
                                              track.preferredTransform);
    *upright = CGAffineTransformConcat(track.preferredTransform,
                                       CGAffineTransformMakeTranslation(-CGRectGetMinX(shown), -CGRectGetMinY(shown)));
    return CGSizeMake(fabs(shown.size.width), fabs(shown.size.height));
}

// H.264 wants even sides.
static CGFloat even(CGFloat value) {
    return 2 * floor(value / 2);
}

static void crop(AVURLAsset *asset, AVAssetTrack *track, NSURL *into, CGFloat aspect, void (^done)(NSURL *cropped, NSString *note)) {
    CGAffineTransform upright;
    CGSize shown = shownSize(track, &upright);
    if (shown.width < 2 || shown.height < 2) {
        done(nil, @"no picture");
        return;
    }
    if (fabs(shown.width / shown.height - aspect) < kAspectSlack) {
        done(asset.URL, @"already the right shape");
        return;
    }
    CGSize render = shown.width / shown.height > aspect ? CGSizeMake(even(shown.height * aspect), even(shown.height))
                                                        : CGSizeMake(even(shown.width), even(shown.width / aspect));
    AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:CGAffineTransformConcat(upright, CGAffineTransformMakeTranslation((render.width - shown.width) / 2,
                                                                                          (render.height - shown.height) / 2))
                 atTime:kCMTimeZero];
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = track.timeRange;
    instruction.layerInstructions = @[layer];
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = render;
    composition.frameDuration = CMTimeMake(1, track.nominalFrameRate > 1 ? (int32_t)lround(track.nominalFrameRate) : 30);
    composition.instructions = @[instruction];

    AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    if (!export) {
        done(nil, @"no exporter");
        return;
    }
    // Exported beside the destination and moved in on success
    // (Batch 93): a failed crop used to leave its partial AT the
    // final name, where existence alone made it the cached answer.
    NSURL *partial = [into.URLByDeletingPathExtension URLByAppendingPathExtension:@"partial.mp4"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    export.outputURL = partial;
    export.outputFileType = AVFileTypeMPEG4;
    export.videoComposition = composition;
    [export exportAsynchronouslyWithCompletionHandler:^{
        BOOL ok = export.status == AVAssetExportSessionStatusCompleted;
        dispatch_async(queue(), ^{
            if (ok) {
                [NSFileManager.defaultManager removeItemAtURL:into error:nil];
                ok = [NSFileManager.defaultManager moveItemAtURL:partial toURL:into error:nil];
            }
            if (ok) prune();
            else [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
            done(ok ? into : nil, ok ? [NSString stringWithFormat:@"cropped to %.0fx%.0f", render.width, render.height]
                                     : [NSString stringWithFormat:@"crop failed: %@", export.error.localizedDescription]);
        });
    }];
}

void SGArtworkCrop(NSURL *file, NSString *identifier, CGFloat aspect, void (^done)(NSURL *cropped, NSString *note)) {
    NSURL *into = fileFor([NSString stringWithFormat:@"%@-%.2f.mp4", identifier, aspect]);
    if ([NSFileManager.defaultManager fileExistsAtPath:into.path]) {
        dispatch_async(queue(), ^{ touch(into); });
        done(into, @"cropped already");
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        dispatch_async(queue(), ^{
            if (!tracks.count) {
                done(nil, [NSString stringWithFormat:@"no video track: %@", error.localizedDescription]);
                return;
            }
            crop(asset, tracks.firstObject, into, aspect, done);
        });
    }];
}

void SGArtworkFirstFrame(NSURL *file, void (^done)(CGImageRef frame)) {
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:file options:nil]];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    [generator generateCGImageAsynchronouslyForTime:kCMTimeZero completionHandler:^(CGImageRef frame, CMTime actual, NSError *error) {
        done(frame);
    }];
}
