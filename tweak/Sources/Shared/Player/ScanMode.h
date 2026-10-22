// Scan mode (personal fork, Batch 75): skim a playlist the way you
// would flip through a crate — each track plays a short slice, then
// the next one starts. The slice's length and where it is taken from
// are choices on the Player page; there is no hook detection here and
// the settings say so — "from the middle" is a place, not a promise.
// Off until switched on; a pause holds the slice where it is.
#import <Foundation/Foundation.h>

@class SGModRow;
NSArray<SGModRow *> *SGScanModeRows(void);

#define SGKeyScanMode @"spotifyglass.scan"
#define SGKeyScanSeconds @"spotifyglass.scan.seconds"  // choice index: 10 / 15 / 30
#define SGKeyScanOffset @"spotifyglass.scan.offset"    // choice index: 0 start, 1 middle

// The slice for the stored choice index, in seconds.
double SGScanSliceSeconds(void);
