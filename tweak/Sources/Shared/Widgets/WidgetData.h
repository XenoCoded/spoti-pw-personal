// The mod's widgets' data (Batch 68): the tweak writes what the home and
// lock screen widgets show — the playing song and its current line, and
// the day's listening — into the suite Spotify's own widget reads,
// group.com.spotify.client.widget.data. The App Groups shim redirects
// that suite into a folder the app and the widget extension share, so
// the widget reads back what is written here. Nothing leaves the phone.
#import <Foundation/Foundation.h>

#define SGKeyWidgets @"spotifyglass.widgets"

@class SGModRow;
// Writes the current song, line and stats into the suite, and asks the
// widgets to reload when the song changes. Cheap; called on player
// state changes and on a slow timer for the line.
void SGWidgetDataWrite(void);
// The Lock screen page's Widgets section: the one switch.
NSArray<SGModRow *> *SGWidgetRows(void);
