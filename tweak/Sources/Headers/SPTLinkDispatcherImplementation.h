// Spotify's link dispatcher, a singleton the app builds at startup; the route the app itself takes
// for a link it opens.
#import <Foundation/Foundation.h>

@interface SPTLinkDispatcherImplementation : NSObject
// The 9.1.90 shape (verified against the 9.1.90 executable): the
// interactionID form the 9.1.78 headers declared no longer exists.
// options is an integer bitmask in the binary's own type encoding
// (v56@0:8@16q24@32@?40@?48), not an object (Batch 94).
- (void)navigateToURI:(NSURL *)uri options:(long long)options reason:(id)reason
    completionHandler:(id)completionHandler resultHandler:(id)resultHandler;
@end
