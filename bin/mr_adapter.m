// SPDX-License-Identifier: BSD-3-Clause
// Derived from: https://github.com/ungive/mediaremote-adapter
// Copyright (c) 2025 Jonas van den Berg and contributors
// See LICENSE-third-party.txt for the full BSD-3-Clause license.
//
// mr_adapter.m — MediaRemote adapter loaded by /usr/bin/perl (Apple-signed).
// perl's com.apple.* signing lets MediaRemote's caller-check (macOS 15.4+/26) pass.
// Exports adapter_get_env (invoked via DynaLoader::dl_install_xsub in loader.pl).
// Prints one JSON line to stdout: {"title","artist","playing"}.
//
// Build: clang -fobjc-arc -dynamiclib -framework Foundation mr_adapter.m -o libmr_adapter.dylib
// Sign:  codesign -s - --force libmr_adapter.dylib
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

typedef void (^InfoHandler)(NSDictionary *info);
typedef void (^ClientHandler)(id client);
typedef void (^PlayingHandler)(BOOL playing);

static NSString *str(id v) { return [v isKindOfClass:[NSString class]] ? v : [v description]; }

__attribute__((visibility("default")))
void adapter_get_env(void) {
    @autoreleasepool {
        NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        [b load];
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) { printf("{\"playing\":false,\"error\":\"dlopen_failed\"}\n"); fflush(stdout); return; }
        typedef void (*GetInfo)(dispatch_queue_t, InfoHandler);
        typedef void (*GetClient)(dispatch_queue_t, ClientHandler);
        typedef void (*GetPlaying)(dispatch_queue_t, PlayingHandler);
        GetInfo gi = (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        GetClient gc = (GetClient)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        GetPlaying gp = (GetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        if (!gi) { printf("{\"playing\":false,\"error\":\"dlsym_failed\"}\n"); fflush(stdout); return; }

        // All three callbacks fire asynchronously on a worker thread (we pass a
        // serial queue q). The main-thread runloop spin below just lets us wait for
        // them with a timeout. IMPORTANT: wait for ALL expected callbacks, not just
        // the first — the old `while (got == 0)` exited as soon as the info callback
        // arrived, which often beat the playing callback, so `playing` read as stale NO.
        dispatch_queue_t q = dispatch_queue_create("com.mediaremote.queue", NULL);
        __block NSDictionary *info = nil;
        __block BOOL playing = NO;
        __block int got = 0;
        int expected = (gi ? 1 : 0) + (gc ? 1 : 0) + (gp ? 1 : 0);
        if (gc) gc(q, ^(id client){ got++; });
        gi(q, ^(NSDictionary *i){ info = i; got++; });
        if (gp) gp(q, ^(BOOL p){ playing = p; got++; });

        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (got < expected && [[NSDate date] compare:limit] == NSOrderedAscending) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:limit];
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        if (info) {
            NSString *title  = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            NSString *artist = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            if (title.length)  out[@"title"]  = title;
            if (artist.length) out[@"artist"] = artist;
            // Prefer the explicit playing flag; fall back to playback rate > 0 if the
            // playing callback didn't land in time.
            double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
            BOOL pl = (got >= expected || gp == NULL) ? playing : (rate > 0.0);
            out[@"playing"] = @(pl);
        } else {
            out[@"playing"] = @(playing);
        }
        NSData *d = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        printf("%s\n", [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] UTF8String] ?: "{}");
        fflush(stdout);
    }
}
