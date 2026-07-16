// nowplaying.m — read macOS Now Playing via private MediaRemote framework.
// Callback runs on a background serial queue; main thread waits on a semaphore.
// No runloop, no deadlock. Prints one JSON line.
// Build: clang -fobjc-arc -framework Foundation nowplaying.m -o nowplaying
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

typedef void (^MRNowPlayingInfoHandler)(NSDictionary *info, NSError *error);
typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t _Nonnull, MRNowPlayingInfoHandler _Nonnull);

static NSString *str(id v) { return [v isKindOfClass:[NSString class]] ? v : [v description]; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        [b load];
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { printf("{\"playing\":false,\"error\":\"dlopen_failed\"}\n"); return 2; }
        MRGetNowPlayingInfo get = (MRGetNowPlayingInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        if (!get) { printf("{\"playing\":false,\"error\":\"dlsym_failed\"}\n"); return 3; }

        __block NSDictionary *info = nil;
        dispatch_queue_t q = dispatch_queue_create("np.read", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        MRNowPlayingInfoHandler handler = ^(NSDictionary *i, NSError *e) {
            info = i;
            dispatch_semaphore_signal(sem);
        };
        get(q, [handler copy]);
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        if (waited == 0 && info) {
            NSString *title  = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            NSString *artist = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            NSString *album  = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
            if (title && title.length)  out[@"title"]  = title;
            if (artist && artist.length) out[@"artist"] = artist;
            if (album && album.length)  out[@"album"]  = album;
            out[@"playing"] = @YES;
        } else {
            out[@"playing"] = @NO;
        }
        NSData *j = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
        printf("%s\n", s.UTF8String ?: "{}");
        return 0;
    }
}
