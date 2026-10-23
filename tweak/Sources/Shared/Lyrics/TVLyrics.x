// The big screen lyric page's server: one listening socket on the
// loopback address and nothing else — 127.0.0.1 by construction, so the
// page can be opened on this phone and nowhere else. It answers one
// request at a time (the page polls twice a second and each answer is
// small), reads the karaoke state on the main thread where that state
// lives, and polls its socket so switching it off stops it cleanly.
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <poll.h>
#import <unistd.h>
#import "Core/SGCore.h"
#import "TVLyrics.h"
#import "Shared/Player/PlayerState.h"

static int sg_listen = -1;
static BOOL sg_serving;

// The state builders live on the main thread; the server thread borrows it.
static NSData *onMain(NSData * (^work)(void)) {
    if (NSThread.isMainThread) return work();
    __block NSData *data = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ data = work(); });
    return data;
}

static void respond(int fd, NSString *status, NSString *type, NSData *body) {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.0 %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        status, type, (unsigned long)body.length];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, headData.bytes, headData.length, 0);
    if (body.length) send(fd, body.bytes, body.length, 0);
}

static void serveClient(int fd) {
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char buf[2048];
    ssize_t got = recv(fd, buf, sizeof(buf) - 1, 0);
    if (got <= 0) return;
    buf[got] = 0;
    NSString *request = [NSString stringWithCString:buf encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *parts = [request componentsSeparatedByString:@" "];
    NSString *path = parts.count > 1 ? parts[1] : @"/";
    path = [path componentsSeparatedByString:@"?"].firstObject ?: @"/";
    if ([path isEqualToString:@"/"]) {
        respond(fd, @"200 OK", @"text/html; charset=utf-8",
            [SGTVLyricsPageHTML() dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([path isEqualToString:@"/state"]) {
        NSData *json = onMain(^{ return SGTVLyricsStateJSON(); });
        if (json) respond(fd, @"200 OK", @"application/json", json);
        else respond(fd, @"500 Later", @"text/plain", [NSData data]);
    } else if ([path isEqualToString:@"/cover.jpg"]) {
        NSData *jpeg = onMain(^{ return SGTVLyricsCoverJPEG(); });
        if (jpeg) respond(fd, @"200 OK", @"image/jpeg", jpeg);
        else respond(fd, @"404 Not Found", @"text/plain", [@"no cover" dataUsingEncoding:NSUTF8StringEncoding]);
    } else {
        respond(fd, @"404 Not Found", @"text/plain", [@"not here" dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

// A generation per server run (Batch 90): the loop used to poll the
// shared sg_listen and the shared serving flag, so a fast off-on left
// the old loop looking at the new listener — its fd number reused —
// and it never went away. A loop now serves only its own generation
// and its own socket.
static NSUInteger sg_acceptGeneration;

static void acceptLoop(NSUInteger generation, int listenFd) {
    while (sg_serving && generation == sg_acceptGeneration) {
        struct pollfd pfd = {listenFd, POLLIN, 0};
        if (poll(&pfd, 1, 500) <= 0 || !(pfd.revents & POLLIN)) continue;
        int fd = accept(listenFd, NULL, NULL);
        if (fd < 0) continue;
        // The poll can wake a loop whose run already ended (Batch 93):
        // a fast off-on reuses the fd number, and this loop would serve
        // one client off the new listener before its next check.
        if (!sg_serving || generation != sg_acceptGeneration) { close(fd); break; }
        serveClient(fd);
        close(fd);
    }
}

static void startServer(void) {
    if (sg_serving) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(SGTVLyricsPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // this phone only, by design
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        SGLog(@"tv lyrics: could not take port %d", SGTVLyricsPort);
        close(fd);
        return;
    }
    sg_listen = fd;
    sg_serving = YES;
    NSUInteger generation = ++sg_acceptGeneration;
    [NSThread detachNewThreadWithBlock:^{ acceptLoop(generation, fd); }];
    SGLog(@"tv lyrics: serving at http://127.0.0.1:%d", SGTVLyricsPort);
}

static void stopServer(void) {
    if (!sg_serving) return;
    sg_acceptGeneration++;
    sg_serving = NO;   // the loop notices within half a second and lets go
    close(sg_listen);
    sg_listen = -1;
    SGLog(@"tv lyrics: stopped");
}

// Read on every player state change, like the head gestures: flipping
// the switch takes hold on the next track at the latest, no restart.
static void refresh(void) {
    if (SGFlag(SGKeyTVLyrics, NO)) startServer();
    else stopServer();
}

@interface SGTVLyricsWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGTVLyricsWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    refresh();
}
@end

// Held in a static: the observer registry is weak (PlayerState.x), so a
// bare temporary deallocates as the constructor returns — toggling the
// big screen after launch neither started nor stopped the server.
static SGTVLyricsWatcher *sg_watcher;
static id sg_defaultsObserver;

%ctor {
    sg_watcher = [SGTVLyricsWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    // The switch also re-reads the moment it changes (Batch 94),
    // like the head gestures: state changes alone could leave the
    // server running (or stopped) through a long pause.
    sg_defaultsObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { refresh(); }];
    refresh();
}
