// Animated lyric artwork (personal fork): the lyric stills' moving sibling. A
// style that moves is rendered frame by frame into a short H.264 clip and handed
// to the system as an MPMediaItemAnimatedArtwork, the iOS 26 channel the base's
// Canvas artwork uses. Clips are cached per track, line and style under Caches,
// so a song replayed is a song already rendered; the newest 60 are kept.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// What the clip cache weighs, and emptying it (the Storage rows).
unsigned long long SGLyricClipCacheBytes(void);
// Mark a key as on screen: pruning leaves its clip alone (Batch 21).
void SGLyricClipSetProtected(NSString *key);
void SGLyricClipCacheClear(void);
// The cached clip for a key (track/line/style), or nil when none is rendered yet.
NSURL *SGLyricClipCachedFile(NSString *key);
// Renders a clip: frameAt is called on a background queue for each frame's time
// in seconds; completion lands on the main queue with the file, or nil when the
// render failed. A key already rendering is not rendered twice.
// Renders a clip, or answers from the cache. `priority` is the line on
// screen (Batch 30); speculative work (warming) is dropped with nil while
// a priority render is in flight, so the line nobody is waiting for never
// queues ahead of the one everybody is. The completion always lands on the
// main queue, whatever path is taken.
void SGLyricClipRender(NSString *key, CGSize size, NSInteger fps, double duration, BOOL priority,
                       UIImage *(^frameAt)(double t), void (^completion)(NSURL *file));
