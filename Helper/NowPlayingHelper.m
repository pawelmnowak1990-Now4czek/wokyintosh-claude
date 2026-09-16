// Pomocnik Now Playing dla Wokyintosha.
// Od macOS 15.4 MediaRemote odpowiada tylko procesom Apple, dlatego ta biblioteka
// jest ładowana do /usr/bin/perl (nowplaying-helper.pl). Protokół: sekcja 5 specu
// docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (^MRClientsBlock)(CFArrayRef clients);
typedef void (^MRInfoBlock)(CFDictionaryRef info, void *unused);
typedef void (^MRCommandBlock)(uint32_t error, CFArrayRef statuses);

static void (*MRGetClients)(dispatch_queue_t, MRClientsBlock);
static CFTypeRef (*MRGetLocalOrigin)(void);
static void (*MRGetInfoForClient)(CFTypeRef client, CFTypeRef origin, Boolean includeArtwork, dispatch_queue_t, MRInfoBlock);
static CFStringRef (*MRClientBundle)(CFTypeRef);
static CFStringRef (*MRClientDisplayName)(CFTypeRef);
static Boolean (*MRSendCommandToClient)(uint32_t command, CFDictionaryRef options, CFTypeRef origin, CFTypeRef client, uint32_t appOptions, dispatch_queue_t, MRCommandBlock);

static const uint32_t kCommandTogglePlayPause = 2;
static const uint32_t kCommandNextTrack = 4;
static const uint32_t kCommandPreviousTrack = 5;
static const NSUInteger kMaxArtworkBytes = 2 * 1024 * 1024;
static const int64_t kCallTimeout = 3 * NSEC_PER_SEC;

static dispatch_queue_t mrQueue;
static NSLock *outputLock;
static NSLock *clientsLock;
static NSDictionary<NSString *, id> *latestClients;
static NSMutableDictionary<NSString *, NSString *> *sentArtworkIds;

static NSString *InfoKey(NSString *name) {
    return [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name];
}

static void WriteLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    [outputLock lock];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    [outputLock unlock];
}

static void *RequireSymbol(void *handle, const char *name) {
    void *symbol = handle ? dlsym(handle, name) : NULL;
    if (!symbol) {
        WriteLine(@{@"type": @"error", @"reason": @"missing-symbol", @"symbol": @(name)});
        _exit(3);
    }
    return symbol;
}

static NSString *StringValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static double NumberValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

static double DateValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    return [value isKindOfClass:[NSDate class]] ? [value timeIntervalSince1970] : 0;
}

static NSArray *CopyClients(void) {
    __block NSArray *result = @[];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetClients(mrQueue, ^(CFArrayRef clients) {
        if (clients) result = [(__bridge NSArray *)clients copy];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kCallTimeout)) != 0) return @[];
    return result;
}

static NSDictionary *CopyInfo(id client, BOOL includeArtwork) {
    __block NSDictionary *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetInfoForClient((__bridge CFTypeRef)client, MRGetLocalOrigin(), includeArtwork, mrQueue, ^(CFDictionaryRef info, void *unused) {
        if (info) result = [(__bridge NSDictionary *)info copy];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kCallTimeout)) != 0) return nil;
    return result;
}

static void SendArtwork(id client, NSString *bundle, NSString *artworkId) {
    NSDictionary *info = CopyInfo(client, YES);
    id data = info[InfoKey(@"ArtworkData")];
    if (![data isKindOfClass:[NSData class]] || [data length] == 0 || [data length] > kMaxArtworkBytes) return;
    NSString *mime = StringValue(info, @"ArtworkMIMEType");
    WriteLine(@{
        @"type": @"artwork",
        @"bundle": bundle,
        @"artworkId": artworkId,
        @"mime": mime.length > 0 ? mime : @"image/jpeg",
        @"data": [data base64EncodedStringWithOptions:0],
    });
}

static void PollOnce(void) {
    NSMutableArray *players = [NSMutableArray array];
    NSMutableDictionary *clientsByBundle = [NSMutableDictionary dictionary];
    for (id client in CopyClients()) {
        NSString *bundle = (__bridge NSString *)MRClientBundle((__bridge CFTypeRef)client);
        if (bundle.length == 0) continue;
        clientsByBundle[bundle] = client;

        NSDictionary *info = CopyInfo(client, NO);
        NSString *title = StringValue(info, @"Title");
        if ([title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) continue;

        NSString *name = (__bridge NSString *)MRClientDisplayName((__bridge CFTypeRef)client) ?: @"";
        NSString *artworkId = StringValue(info, @"ArtworkIdentifier");
        // Okładka tylko przy nowym identyfikatorze i przed linią state, żeby aplikacja miała bajty,
        // zanim zobaczy identyfikator. Nieudana próba też jest zapamiętana, bez ponawiania co sekundę.
        if (artworkId.length > 0 && ![sentArtworkIds[bundle] isEqualToString:artworkId]) {
            sentArtworkIds[bundle] = artworkId;
            SendArtwork(client, bundle, artworkId);
        }

        [players addObject:@{
            @"bundle": bundle,
            @"name": name,
            @"title": title,
            @"artist": StringValue(info, @"Artist"),
            @"album": StringValue(info, @"Album"),
            @"duration": @(NumberValue(info, @"Duration")),
            @"elapsed": @(NumberValue(info, @"ElapsedTime")),
            @"rate": @(NumberValue(info, @"PlaybackRate")),
            @"timestamp": @(DateValue(info, @"Timestamp")),
            @"artworkId": artworkId,
        }];
    }
    [clientsLock lock];
    latestClients = clientsByBundle;
    [clientsLock unlock];
    WriteLine(@{@"type": @"state", @"players": players});
}

static BOOL StatusesOK(CFArrayRef statuses) {
    for (id status in (__bridge NSArray *)statuses) {
        if ([status isKindOfClass:[NSNumber class]] && [status unsignedIntValue] != 0) return NO;
    }
    return YES;
}

static void WriteAck(NSString *cmd, NSString *bundle, BOOL ok) {
    WriteLine(@{@"type": @"ack", @"cmd": cmd, @"bundle": bundle, @"ok": @(ok)});
}

static void HandleCommand(NSData *line) {
    id json = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = [json[@"cmd"] isKindOfClass:[NSString class]] ? json[@"cmd"] : @"";
    NSString *bundle = [json[@"bundle"] isKindOfClass:[NSString class]] ? json[@"bundle"] : @"";

    uint32_t command;
    if ([cmd isEqualToString:@"togglePlayPause"]) command = kCommandTogglePlayPause;
    else if ([cmd isEqualToString:@"nextTrack"]) command = kCommandNextTrack;
    else if ([cmd isEqualToString:@"previousTrack"]) command = kCommandPreviousTrack;
    else { WriteAck(cmd, bundle, NO); return; }

    [clientsLock lock];
    id client = latestClients[bundle];
    [clientsLock unlock];
    if (!client) { WriteAck(cmd, bundle, NO); return; }

    Boolean accepted = MRSendCommandToClient(command, NULL, MRGetLocalOrigin(), (__bridge CFTypeRef)client, 0, mrQueue, ^(uint32_t error, CFArrayRef statuses) {
        WriteAck(cmd, bundle, error == 0 && StatusesOK(statuses));
    });
    if (!accepted) WriteAck(cmd, bundle, NO);
}

static void *ReadCommands(void *unused) {
    char *buffer = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&buffer, &capacity, stdin)) > 0) {
        @autoreleasepool {
            HandleCommand([NSData dataWithBytes:buffer length:(NSUInteger)length]);
        }
    }
    // Wejście zamknięte: aplikacja skończyła albo padła. _exit omija destruktory perla.
    fflush(stdout);
    _exit(0);
    return NULL;
}

__attribute__((constructor))
static void RunHelper(void) {
    @autoreleasepool {
        outputLock = [NSLock new];
        clientsLock = [NSLock new];
        latestClients = @{};
        sentArtworkIds = [NSMutableDictionary dictionary];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        MRGetClients = RequireSymbol(mr, "MRMediaRemoteGetNowPlayingClients");
        MRGetLocalOrigin = RequireSymbol(mr, "MRMediaRemoteGetLocalOrigin");
        MRGetInfoForClient = RequireSymbol(mr, "MRMediaRemoteGetNowPlayingInfoForClient");
        MRClientBundle = RequireSymbol(mr, "MRNowPlayingClientGetBundleIdentifier");
        MRClientDisplayName = RequireSymbol(mr, "MRNowPlayingClientGetDisplayName");
        MRSendCommandToClient = RequireSymbol(mr, "MRMediaRemoteSendCommandToClient");

        mrQueue = dispatch_queue_create("wokyintosh.nowplaying.mediaremote", DISPATCH_QUEUE_SERIAL);
        WriteLine(@{@"type": @"hello", @"version": @1});

        pthread_t reader;
        pthread_create(&reader, NULL, ReadCommands, NULL);
        pthread_detach(reader);
    }
    for (;;) {
        @autoreleasepool {
            PollOnce();
        }
        sleep(1);
    }
}
