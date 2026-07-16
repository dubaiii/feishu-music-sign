// mr_adapter.m — faithful replication of mediaremote-rs's adapter_get_env.
// Exported C function called by perl via dl_install_xsub (NOT a constructor).
// Runs in perl's Apple-signed process -> MediaRemote caller check passes.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

typedef void (^InfoHandler)(NSDictionary *info);
typedef void (^ClientHandler)(id client);
typedef void (^PlayingHandler)(BOOL playing);

__attribute__((visibility("default")))
void adapter_get_env(void) {
    @autoreleasepool {
        NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        [b load];
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) { printf("null\n"); fflush(stdout); return; }
        typedef void (*GetInfo)(dispatch_queue_t, InfoHandler);
        typedef void (*GetClient)(dispatch_queue_t, ClientHandler);
        typedef void (*GetPlaying)(dispatch_queue_t, PlayingHandler);
        GetInfo gi = (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        GetClient gc = (GetClient)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        GetPlaying gp = (GetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        if (!gi) { printf("null\n"); fflush(stdout); return; }

        dispatch_queue_t q = dispatch_queue_create("com.mediaremote.queue", NULL);
        __block NSDictionary *info = nil;
        __block BOOL playing = NO;
        __block int got = 0;
        if (gc) gc(q, ^(id client){ got++; });
        gi(q, ^(NSDictionary *i){ info = i; got++; });
        if (gp) gp(q, ^(BOOL p){ playing = p; got++; });

        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:0.6];
        while (got == 0 && [[NSDate date] compare:limit] == NSOrderedAscending) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:limit];
        }

        if (info) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            NSString *title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description];
            NSString *artist = [info[@"kMRMediaRemoteNowPlayingInfoArtist"] description];
            if (title.length) out[@"title"] = title;
            if (artist.length) out[@"artist"] = artist;
            out[@"playing"] = @(playing);
            NSData *d = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
            printf("%s\n", [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String]);
        } else {
            printf("null\n");
        }
        fflush(stdout);
    }
}
