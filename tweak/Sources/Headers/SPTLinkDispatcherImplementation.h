// Spotify's link dispatcher, a singleton the app builds at startup; the route the app itself takes
// for a link it opens.
#import <Foundation/Foundation.h>

@interface SPTLinkDispatcherImplementation : NSObject
// The 9.1.90 shape (verified against the 9.1.90 executable): the
// interactionID form the 9.1.78 headers declared no longer exists.
- (void)navigateToURI:(NSURL *)uri options:(id)options reason:(id)reason
    completionHandler:(id)completionHandler resultHandler:(id)resultHandler;
@end
