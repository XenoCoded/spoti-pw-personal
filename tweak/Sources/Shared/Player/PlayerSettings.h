// Settings of the player that hold for either look.
#import <UIKit/UIKit.h>

UIViewController *SGLockScreenSettingsPage(void);

// The queue as text (Batch 25): a row on the Player page that copies the
// playing track and what's up next to the pasteboard.
@class SGModRow;
NSArray<SGModRow *> *SGQueueShareRows(void);
