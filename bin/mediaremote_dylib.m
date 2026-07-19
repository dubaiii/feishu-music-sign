// SPDX-License-Identifier: BSD-3-Clause
// Derived from: https://github.com/ungive/mediaremote-adapter
// Copyright (c) 2025 Jonas van den Berg and contributors
// Full BSD-3-Clause text: https://github.com/ungive/mediaremote-adapter (upstream).
//
// mediaremote_dylib.m
// A dylib loaded by /usr/bin/perl. perl is Apple-signed (com.apple.* system app),
// so MediaRemote's caller-check (macOS 15.4+) permits it — unlike an ad-hoc binary.
// The constructor runs at dlopen time, calls MRMediaRemoteGetNowPlayingInfo, and
// prints one JSON line to stdout. Covers ALL system Now-Playing players
// (Spotify/Apple Music/QQ音乐/网易云/酷狗/汽水音乐/Chrome…) system-wide.
//
// Build: clang -fobjc-arc -dynamiclib -framework Foundation mediaremote_dylib.m -o libmr.dylib
// Sign:  codesign -s - --force libmr.dylib
// Run:   /usr/bin/perl -MDynaLoader -e 'DynaLoader::dl_load_file($ARGV[0],0)' libmr.dylib

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

typedef void (^MRNowPlayingInfoHandler)(NSDictionary *info, NSError *error);
typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t _Nonnull, MRNowPlayingInfoHandler _Nonnull);

static NSString *str(id v) { return [v isKindOfClass:[NSString class]] ? v : [v description]; }

static void run() {
    NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    [b load];
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { printf("{\"playing\":false,\"error\":\"dlopen_failed\"}\n"); fflush(stdout); return; }
    MRGetNowPlayingInfo get = (MRGetNowPlayingInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    if (!get) { printf("{\"playing\":false,\"error\":\"dlsym_failed\"}\n"); fflush(stdout); return; }

    __block NSDictionary *info = nil;
    __block BOOL done = NO;
    MRNowPlayingInfoHandler handler = ^(NSDictionary *i, NSError *e) {
        info = i;
        done = YES;
        CFRunLoopStop(CFRunLoopGetMain());
    };
    // MediaRemote dispatches the completion to the main queue; run the main runloop
    // briefly so it fires. (Perl has no main runloop by default, so we must spin one.)
    get(dispatch_get_main_queue(), [handler copy]);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false);

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (done && info) {
        NSString *title  = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        NSString *artist = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        NSString *album  = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        if (title && title.length)  out[@"title"]  = title;
        if (artist && artist.length) out[@"artist"] = artist;
        if (album && album.length)  out[@"album"]  = album;
        out[@"playing"] = @YES;
    } else {
        out[@"playing"] = @NO;
        if (!done) out[@"error"] = @"timeout";
    }
    NSData *j = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    printf("%s\n", s.UTF8String ?: "{}");
    fflush(stdout);
}

__attribute__((constructor))
static void mediaremote_ctor(void) {
    @autoreleasepool { run(); }
}
