// The queue vault (personal fork, Batch 86): snapshots of the queue as it
// was — the playing track and what's up next, titles and URIs — kept in
// the mod's own defaults, newest twenty. Spotify offers no way to write
// the queue back, so a snapshot is a manifest: tap to copy the list, or
// play its first track and rebuild from there. A great queue stops
// evaporating.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define SGKeyQueueVault @"spotifyglass.queueVault"

// Newest first. Each snapshot: name, t (timestamp), context, and tracks
// as {title, artist, uri} dicts, the playing track first.
NSArray<NSDictionary *> *SGQueueSnapshots(void);
// Captures the current track and the up-next queue. Nothing playing,
// nothing captured.
void SGQueueSnapshotNow(void);
void SGQueueSnapshotForget(NSDictionary *snapshot);
void SGQueueVaultClear(void);
// The manifest as text: the snapshot's name, where it came from, one
// track a line, and the first track's share link to start from.
NSString *SGQueueSnapshotText(NSDictionary *snapshot);

UIViewController *SGQueueVaultPage(void);
