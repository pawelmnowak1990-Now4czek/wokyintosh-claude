// Pomocnik Now Playing dla Wokyintosha.
// Od macOS 15.4 MediaRemote odpowiada tylko procesom Apple, dlatego ta biblioteka
// jest ładowana do /usr/bin/perl (nowplaying-helper.pl). Protokół: sekcja 5 specu
// docs/superpowers/specs/2026-09-16-wokyintosh-now-playing-mediaremote-design.md.
// Pętla NIE działa w konstruktorze biblioteki — ładowanie trzyma blokadę dyld przez
// cały czas trwania dl_load_file, więc każdy leniwy dlopen (miękkie linkowanie we
// frameworkach Apple) zawiesiłby się na zawsze. Zamiast tego perl woła wyeksportowaną
// NowPlayingHelperRun przez sztuczkę z XSUB-em (dl_find_symbol + dl_install_xsub),
// już po zakończeniu ładowania biblioteki.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
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
// Budżet czasu na jeden poll: wszystkie zapytania o info (i osobno zapytanie o okładkę)
// muszą zmieścić się w tym oknie, inaczej pomocnik korzysta z cache/poprzedniej listy.
static const int64_t kInfoDeadlineNanos = (int64_t)(0.8 * (double)NSEC_PER_SEC);
// Najstarszy wpis w cache info, który jeszcze trafia do linii state.
static const NSTimeInterval kInfoCacheMaxAge = 10.0;
// Ile trzeba odczekać od wysłania zapytania o info, zanim wolno spróbować znowu dla tego
// samego bundle — inaczej odtwarzacz, który raz nie odpowiedział, nigdy nie dostałby kolejnej
// szansy (i po kInfoCacheMaxAge zniknąłby z state na stałe, mimo że dalej gra).
static const NSTimeInterval kInfoRequestRetryAfter = 3.0;

// Wpis cache info dla jednego bundle: ostatnia udana odpowiedź MediaRemote + czas jej
// przyjęcia. Odświeżany także wtedy, gdy odpowiedź przychodzi już po budżecie pollu —
// wtedy po prostu obsłuży kolejny poll.
@interface InfoCacheEntry : NSObject
@property(nonatomic, strong) NSDictionary *info;
@property(nonatomic, assign) NSTimeInterval receivedAt;
@end
@implementation InfoCacheEntry
@end

static dispatch_queue_t mrQueue;
static NSLock *outputLock;
static NSLock *clientsLock;
static NSDictionary<NSString *, id> *latestClients;
static NSArray *lastKnownClientsList;
static NSMutableDictionary<NSString *, NSString *> *sentArtworkIds;
static NSLock *cacheLock;
static NSMutableDictionary<NSString *, InfoCacheEntry *> *infoCache;
// bundle -> czas (CFAbsoluteTimeGetCurrent) wysłania zapytania, na które jeszcze nie przyszła
// odpowiedź. NSNumber zamiast NSSet, żeby dało się rozpoznać "za stare, można ponowić" i
// odróżnić spóźnioną odpowiedź do starej prośby od odpowiedzi na aktualną.
static NSMutableDictionary<NSString *, NSNumber *> *pendingInfoRequests;

static NSString *InfoKey(NSString *name) {
    return [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name];
}

// Odtwarzacze to obce procesy — ich stringi mogą zawierać niesparowane surogaty i inne
// nie-UTF8 śmieci, które wywalają NSJSONSerialization. Czyszczenie przez zgubny round-trip
// przez UTF-8 daje zawsze poprawny, serializowalny string (ewentualnie z utratą znaków).
static NSString *SanitizeString(NSString *value) {
    if (value.length == 0) return @"";
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (!utf8) return @"";
    NSString *clean = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
    return clean ?: @"";
}

static void WriteLine(NSDictionary *object) {
    NSData *json = nil;
    @try {
        NSError *error = nil;
        json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
        if (!json) {
            fprintf(stderr, "nowplaying-helper: serializacja JSON nie powiodła się: %s\n",
                    error ? error.localizedDescription.UTF8String : "nieznany błąd");
            return;
        }
    } @catch (NSException *exception) {
        fprintf(stderr, "nowplaying-helper: wyjątek przy serializacji JSON: %s\n",
                exception.reason.UTF8String ?: "nieznany");
        return;
    }
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
    return [value isKindOfClass:[NSString class]] ? SanitizeString(value) : @"";
}

static double NumberValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    if (![value isKindOfClass:[NSNumber class]]) return 0;
    double number = [value doubleValue];
    return isfinite(number) ? number : 0;
}

static double DateValue(NSDictionary *info, NSString *name) {
    id value = info[InfoKey(name)];
    if (![value isKindOfClass:[NSDate class]]) return 0;
    double seconds = [value timeIntervalSince1970];
    return isfinite(seconds) ? seconds : 0;
}

static NSArray *CopyClients(void) {
    __block NSArray *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetClients(mrQueue, ^(CFArrayRef clients) {
        NSArray *copied = clients ? [(__bridge NSArray *)clients copy] : @[];
        [clientsLock lock];
        lastKnownClientsList = copied;
        [clientsLock unlock];
        result = copied;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kInfoDeadlineNanos)) != 0) {
        // Lista klientów nie zdążyła w budżecie — leć na ostatniej znanej liście.
        [clientsLock lock];
        NSArray *fallback = lastKnownClientsList ?: @[];
        [clientsLock unlock];
        return fallback;
    }
    return result ?: @[];
}

static NSDictionary *CopyInfo(id client, BOOL includeArtwork) {
    __block NSDictionary *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetInfoForClient((__bridge CFTypeRef)client, MRGetLocalOrigin(), includeArtwork, mrQueue, ^(CFDictionaryRef info, void *unused) {
        if (info) result = [(__bridge NSDictionary *)info copy];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kInfoDeadlineNanos)) != 0) return nil;
    return result;
}

// Zamawia info dla jednego bundle, o ile poprzednie zamówienie dla niego albo już dostało
// odpowiedź, albo wisi bez odpowiedzi dłużej niż kInfoRequestRetryAfter — inaczej odtwarzacz,
// który raz nie odpowiedział, nie dostałby już żadnego kolejnego zapytania do końca życia
// pomocnika. Odpowiedź (nawet spóźniona względem budżetu pollu) zawsze trafia do cache —
// obsłuży wtedy kolejny poll zamiast tego bieżącego. Callback czyści pending tylko wtedy, gdy
// wciąż odpowiada za NAJNOWSZĄ prośbę dla tego bundle — spóźniona odpowiedź do starej prośby
// (sprzed retry) nie może skasować pending nowszej prośby, wysłanej już po retry.
static void RequestInfoIfNeeded(NSString *bundle, id client, dispatch_group_t group) {
    NSTimeInterval startedAt = CFAbsoluteTimeGetCurrent();
    [cacheLock lock];
    NSNumber *pendingSince = pendingInfoRequests[bundle];
    BOOL alreadyPending = pendingSince != nil && (startedAt - pendingSince.doubleValue) < kInfoRequestRetryAfter;
    if (!alreadyPending) pendingInfoRequests[bundle] = @(startedAt);
    [cacheLock unlock];
    if (alreadyPending) return;

    dispatch_group_enter(group);
    MRGetInfoForClient((__bridge CFTypeRef)client, MRGetLocalOrigin(), NO, mrQueue, ^(CFDictionaryRef info, void *unused) {
        [cacheLock lock];
        if (info) {
            InfoCacheEntry *entry = [InfoCacheEntry new];
            entry.info = [(__bridge NSDictionary *)info copy];
            entry.receivedAt = CFAbsoluteTimeGetCurrent();
            infoCache[bundle] = entry;
        }
        NSNumber *currentPendingSince = pendingInfoRequests[bundle];
        if (currentPendingSince != nil && currentPendingSince.doubleValue == startedAt) {
            [pendingInfoRequests removeObjectForKey:bundle];
        }
        [cacheLock unlock];
        dispatch_group_leave(group);
    });
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
    NSArray *clients = CopyClients();
    NSMutableDictionary *clientsByBundle = [NSMutableDictionary dictionary];
    // Kolejność pierwszego wystąpienia bundle na liście z MediaRemote — spec §6 pkt 4
    // rozstrzyga remis timestamp kolejnością z listy, więc players musi być deterministyczne,
    // nie zależeć od iteracji po secie.
    NSMutableArray<NSString *> *orderedBundles = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();

    // Wszystkie zapytania o info idą "na raz" — czekamy raz, wspólnie, zamiast po kolei
    // dla każdego klienta. Jeden nieodpowiadający klient nie blokuje już reszty pollu.
    for (id client in clients) {
        NSString *bundle = SanitizeString((__bridge NSString *)MRClientBundle((__bridge CFTypeRef)client));
        if (bundle.length == 0) continue;
        if (clientsByBundle[bundle]) continue; // duplikat na liście MediaRemote — bierzemy pierwsze wystąpienie
        clientsByBundle[bundle] = client;
        [orderedBundles addObject:bundle];
        RequestInfoIfNeeded(bundle, client, group);
    }

    [clientsLock lock];
    latestClients = clientsByBundle;
    [clientsLock unlock];

    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, kInfoDeadlineNanos));
    // Spóźnione odpowiedzi po tym czekaniu i tak zapiszą się do cache (RequestInfoIfNeeded)
    // i posłużą następnemu pollowi.

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    [cacheLock lock];
    for (NSString *bundle in infoCache.allKeys) {
        if (!clientsByBundle[bundle]) [infoCache removeObjectForKey:bundle];
    }
    for (NSString *bundle in pendingInfoRequests.allKeys) {
        if (!clientsByBundle[bundle]) [pendingInfoRequests removeObjectForKey:bundle];
    }
    NSDictionary<NSString *, InfoCacheEntry *> *cacheSnapshot = [infoCache copy];
    [cacheLock unlock];

    NSMutableArray *players = [NSMutableArray array];
    for (NSString *bundle in orderedBundles) {
        id client = clientsByBundle[bundle];
        InfoCacheEntry *entry = cacheSnapshot[bundle];
        if (!entry || (now - entry.receivedAt) > kInfoCacheMaxAge) continue;
        NSDictionary *info = entry.info;

        NSString *title = StringValue(info, @"Title");
        if ([title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) continue;

        NSString *name = SanitizeString((__bridge NSString *)MRClientDisplayName((__bridge CFTypeRef)client) ?: @"");
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

// Wyeksportowana funkcja, wołana przez perl dopiero po zakończeniu dl_load_file (patrz
// nowplaying-helper.pl) — NIE konstruktor biblioteki. Argumenty odpowiadają konwencji
// wywołania XSUB-a (pTHX_ CV*) i są ignorowane. Robi setup i wchodzi w pętlę pollingu,
// która nigdy nie wraca; powrót z tej funkcji oznacza błąd i jest sygnałem dla perla.
__attribute__((visibility("default")))
void NowPlayingHelperRun(void *unusedA, void *unusedB) {
    (void)unusedA;
    (void)unusedB;
    @autoreleasepool {
        outputLock = [NSLock new];
        clientsLock = [NSLock new];
        latestClients = @{};
        sentArtworkIds = [NSMutableDictionary dictionary];
        cacheLock = [NSLock new];
        infoCache = [NSMutableDictionary dictionary];
        pendingInfoRequests = [NSMutableDictionary dictionary];

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
