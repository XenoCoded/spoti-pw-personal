// The clip writer: AVAssetWriter fed pixel buffers, one per frame, each frame a
// UIImage the caller draws. The writer's queue is serial, so two lines' clips
// never render at once — a line change mid-render leaves the older render to
// finish into the cache, where it does no harm and may serve a replay.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "LyricClip.h"

static const NSUInteger kKeptClips = 60;
// A count alone is no ceiling: at Max quality a clip runs to several MB, so
// the cache is also held under a byte budget (Batch 21 audit).
static const unsigned long long kKeptBytes = 120ULL * 1024 * 1024;
// The key whose clip is on screen right now; pruning never takes it.
static NSString *sg_protectedKey;

void SGLyricClipSetProtected(NSString *key) {
    sg_protectedKey = [key copy];
}

static dispatch_queue_t clipQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spoti.pw lyric clips", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSMutableSet<NSString *> *rendering(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// Who is waiting on a key in flight. A line warmed ahead of time and then
// sung needs its publish to survive: completions gather here and all fire
// when the render lands, instead of the later caller being turned away.
static NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSURL *)> *> *waiters(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSURL *)> *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void settle(NSString *key, NSURL *file) {
    NSArray<void (^)(NSURL *)> *waiting;
    @synchronized (rendering()) {
        [rendering() removeObject:key];
        waiting = [waiters()[key] copy];
        [waiters() removeObjectForKey:key];
    }
    for (void (^completion)(NSURL *) in waiting) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(file); });
    }
}

static NSString *clipDirectory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [[caches stringByAppendingPathComponent:@"spoti.pw"] stringByAppendingPathComponent:@"LyricClips"];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return directory;
}

static NSString *clipPath(NSString *key) {
    NSString *safe = [key stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [[clipDirectory() stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"mp4"];
}

unsigned long long SGLyricClipCacheBytes(void) {
    unsigned long long total = 0;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:clipDirectory() error:nil]) {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:
            [clipDirectory() stringByAppendingPathComponent:name] error:nil];
        total += [attrs[NSFileSize] unsignedLongLongValue];
    }
    return total;
}

void SGLyricClipCacheClear(void) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:clipDirectory() error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:[clipDirectory() stringByAppendingPathComponent:name] error:nil];
    }
}

NSURL *SGLyricClipCachedFile(NSString *key) {
    NSString *path = clipPath(key);
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

static void prune(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *name in [files contentsOfDirectoryAtPath:clipDirectory() error:nil]) {
        if ([name.pathExtension isEqualToString:@"mp4"]) {
            NSURL *url = [NSURL fileURLWithPath:[clipDirectory() stringByAppendingPathComponent:name]];
            [urls addObject:url];
            total += [[url resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey] unsignedLongLongValue];
        }
    }
    if (urls.count <= kKeptClips && total <= kKeptBytes) return;
    [urls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = [a resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        NSDate *db = [b resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        return [da compare:db];
    }];
    NSString *protectedName = sg_protectedKey ? [clipPath(sg_protectedKey) lastPathComponent] : nil;
    NSUInteger remaining = urls.count;
    for (NSURL *url in urls) {
        if (remaining <= kKeptClips && total <= kKeptBytes) break;
        if ([url.lastPathComponent isEqualToString:protectedName]) continue;
        total -= [[url resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey] unsignedLongLongValue];
        if ([files removeItemAtURL:url error:nil]) remaining--;
    }
}

static NSMutableSet<NSString *> *priorityKeys(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

void SGLyricClipRender(NSString *key, CGSize size, NSInteger fps, double duration, BOOL priority,
                       UIImage *(^frameAt)(double t), void (^completion)(NSURL *file)) {
    dispatch_async(clipQueue(), ^{
        @synchronized (rendering()) {
            if ([rendering() containsObject:key]) {
                if (!waiters()[key]) waiters()[key] = [NSMutableArray array];
                [waiters()[key] addObject:completion];
                return;
            }
            // A speculative render is not even started while the line on
            // screen is being drawn (Batch 30): the warmer asks again on the
            // next line change if the line still matters.
            if (!priority && priorityKeys().count) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }
            [rendering() addObject:key];
            if (priority) [priorityKeys() addObject:key];
            waiters()[key] = [NSMutableArray arrayWithObject:completion];
        }
        NSURL *file = SGLyricClipCachedFile(key);
        if (file) {
            settle(key, file);
            return;
        }
        // A render that starts in the foreground should be allowed to
        // finish if the phone is locked mid-draw (Batch 54, background
        // audit): the clip is the lock screen's own picture, and an
        // encoder session abandoned to suspension is how background
        // kills happen. The assertion buys the render its seconds; if
        // the system calls time anyway, the flag below cancels the write
        // through the same path as a stall and the partial is discarded.
        __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
        __block BOOL bgExpired = NO;
        bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"spoti.pw lyric clip"
            expirationHandler:^{ bgExpired = YES; }];
        void (^endBgTask)(void) = ^{
            if (bgTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
        };
        NSURL *out = [NSURL fileURLWithPath:clipPath(key)];
        // Render beside the destination and move in at the end, so a killed
        // render never leaves a half clip standing as a finished one.
        NSURL *partial = [out.URLByDeletingPathExtension URLByAppendingPathExtension:@"partial.mp4"];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];

        NSError *error = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:partial fileType:AVFileTypeMPEG4 error:&error];
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @((NSInteger)size.width),
            AVVideoHeightKey: @((NSInteger)size.height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(5 * 1024 * 1024)},
        };
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                        outputSettings:videoSettings];
        input.expectsMediaDataInRealTime = NO;
        NSDictionary *bufferAttributes = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferWidthKey: @((NSInteger)size.width),
            (NSString *)kCVPixelBufferHeightKey: @((NSInteger)size.height),
        };
        AVAssetWriterInputPixelBufferAdaptor *adaptor =
            [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                     sourcePixelBufferAttributes:bufferAttributes];
        BOOL ok = writer && [writer canAddInput:input];
        if (ok) {
            [writer addInput:input];
            ok = [writer startWriting];
            [writer startSessionAtSourceTime:kCMTimeZero];
        }
        CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSInteger frames = MAX(2, (NSInteger)round(duration * fps));
        for (NSInteger frame = 0; frame < frames && ok; frame++) {
            if (bgExpired) {
                SGLog(@"lyric clip: background time called, aborting %@", key);
                ok = NO;
                break;
            }
            // A writer that stops accepting frames (a full disk, a sick
            // session) must not hold the serial queue hostage: five seconds
            // of stall aborts the render and the line keeps its still.
            NSTimeInterval stallStart = 0;
            while (!input.readyForMoreMediaData) {
                if (writer.status != AVAssetWriterStatusWriting) { ok = NO; break; }
                if (!stallStart) stallStart = NSDate.date.timeIntervalSince1970;
                if (NSDate.date.timeIntervalSince1970 - stallStart > 5) {
                    SGLog(@"lyric clip: writer stalled, aborting %@", key);
                    ok = NO;
                    break;
                }
                [NSThread sleepForTimeInterval:0.005];
            }
            if (!ok) break;
            UIImage *image = frameAt(frame / (double)fps);
            if (!image.CGImage) continue;
            CVPixelBufferRef buffer = NULL;
            if (CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess || !buffer) {
                ok = NO;
                break;
            }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),
                                                         size.width, size.height, 8,
                                                         CVPixelBufferGetBytesPerRow(buffer), rgb,
                                                         (CGBitmapInfo)(kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little));
            if (context) {
                CGContextTranslateCTM(context, 0, size.height);
                CGContextScaleCTM(context, 1, -1);
                CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), image.CGImage);
                CGContextRelease(context);
            }
            [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame, (int32_t)fps)];
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            CVPixelBufferRelease(buffer);
        }
        CGColorSpaceRelease(rgb);
        if (!ok) {
            [writer cancelWriting];
            endBgTask();
            settle(key, nil);
            return;
        }
        [input markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            BOOL written = writer.status == AVAssetWriterStatusCompleted;
            NSURL *done = nil;
            if (written) {
                [NSFileManager.defaultManager removeItemAtURL:out error:nil];
                if ([NSFileManager.defaultManager moveItemAtURL:partial toURL:out error:nil]) done = out;
            }
            if (!done) [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
            SGLog(@"lyric clip: %@ %@", key, done ? @"rendered" : @"failed");
            if (done) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ prune(); });
            endBgTask();
            settle(key, done);
            // The caller that started this render is a waiter like any other.
        }];
    });
}
