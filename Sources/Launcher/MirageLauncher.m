// "Mirage for PXPlay" / "Mirage for PXPlay Demo": starts the user's own, unmodified PXPlay
// with the Mirage agent. The PXPlay bundle is never copied or changed; the agent is handed
// to its Java runtime through JAVA_TOOL_OPTIONS.
#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include "../Agent/PXPlayFingerprints.h"

static NSDictionary<NSString *, NSString *> *texts;

static NSString *T(NSString *key) {
    return texts[key] ?: key;
}

static void loadTexts(void) {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"strings" withExtension:@"json"];
    NSDictionary *all = url ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:NULL] : nil;
    NSString *language = @"en";
    NSSet *supported = [NSSet setWithArray:@[@"en", @"de", @"es", @"fr", @"he", @"it", @"ja", @"ko", @"pt", @"ru", @"zh_CN", @"zh_TW"]];
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *tag = preferred.lowercaseString;
        NSString *candidate = [tag componentsSeparatedByString:@"-"].firstObject;
        if ([candidate isEqualToString:@"zh"]) {
            BOOL traditional = [tag containsString:@"hant"] || [tag containsString:@"-tw"] || [tag containsString:@"-hk"] ||
                [tag containsString:@"-mo"];
            candidate = traditional ? @"zh_TW" : @"zh_CN";
        } else if ([candidate isEqualToString:@"iw"]) {
            candidate = @"he";
        }
        if ([supported containsObject:candidate]) {
            language = candidate;
            break;
        }
    }
    NSMutableDictionary *chosen = [NSMutableDictionary dictionary];
    [all enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *values, BOOL *stop) {
        (void)stop;
        if (![key hasPrefix:@"launcher."] && ![key hasPrefix:@"app.reason."]) return;
        NSString *text = values[language] ?: values[@"en"];
        if (text) chosen[key] = text;
    }];
    texts = chosen;
}

static NSModalResponse ask(NSString *title, NSString *detail, NSArray<NSString *> *buttons) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = detail;
    alert.icon = NSApp.applicationIconImage;
    for (NSString *button in buttons) [alert addButtonWithTitle:button];
    return [alert runModal];
}

#pragma mark - PXPlay checks (same rules as the installer)

static BOOL hasArm64(NSString *executable) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:executable];
    NSData *head = [file readDataOfLength:4096];
    [file closeFile];
    if (head.length < sizeof(uint32_t) * 2) return NO;
    const uint8_t *bytes = head.bytes;
    uint32_t magic = *(const uint32_t *)bytes;
    if (magic == MH_MAGIC_64) return ((const struct mach_header_64 *)bytes)->cputype == CPU_TYPE_ARM64;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        uint32_t count = OSSwapBigToHostInt32(((const struct fat_header *)bytes)->nfat_arch);
        const struct fat_arch *arch = (const struct fat_arch *)(bytes + sizeof(struct fat_header));
        for (uint32_t i = 0; i < count && (const uint8_t *)(arch + i + 1) <= bytes + head.length; ++i) {
            if ((cpu_type_t)OSSwapBigToHostInt32((uint32_t)arch[i].cputype) == CPU_TYPE_ARM64) return YES;
        }
    }
    return NO;
}

static BOOL signedByPXPlayDeveloper(NSURL *bundle, NSString *identifier) {
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    NSString *text = [NSString stringWithFormat:
        @"anchor apple generic and certificate leaf[subject.OU] = \"CHDS428K5R\" and identifier \"%@\"", identifier];
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundle, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSDoNotValidateResources, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}

/// nil when the bundle is the expected PXPlay 3.2.0; otherwise a short reason for the user.
static NSString *problemWith(NSURL *app, BOOL demo) {
    NSBundle *bundle = [NSBundle bundleWithURL:app];
    NSString *expected = demo ? @MIRAGE_DEMO_BUNDLE_ID : @MIRAGE_FULL_BUNDLE_ID;
    if (!bundle || ![bundle.bundleIdentifier isEqualToString:expected]) return T(@"app.reason.notPXPlay");
    NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    if (![version isEqualToString:@MIRAGE_PXPLAY_VERSION]) {
        return [T(@"app.reason.version") stringByReplacingOccurrencesOfString:@"{0}" withString:version];
    }
    NSString *jar = [app.path stringByAppendingPathComponent:
        [@"Contents/Resources/Java" stringByAppendingPathComponent:demo ? @MIRAGE_DEMO_JAR : @MIRAGE_FULL_JAR]];
    if (!bundle.executablePath || ![NSFileManager.defaultManager fileExistsAtPath:jar]) return T(@"app.reason.damaged");
    if (!hasArm64(bundle.executablePath)) return T(@"app.reason.intel");
    if (!signedByPXPlayDeveloper(app, expected)) return T(@"app.reason.damaged");
    return nil;
}

#pragma mark - Paths and remembered location

static NSString *homeFolder(void) {
    const char *override = getenv("MIRAGE_HOME");
    if (override && *override) return @(override);
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mirage for PXPlay"];
}

static NSString *configPath(void) {
    return [homeFolder() stringByAppendingPathComponent:@"config.plist"];
}

static void remember(NSURL *app, NSString *slot) {
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithContentsOfFile:configPath()] ?: [NSMutableDictionary dictionary];
    config[slot] = app.path;
    [config writeToFile:configPath() atomically:YES];
}

/// The remembered PXPlay if it is still valid, else the first valid copy macOS knows about.
static NSURL *findPXPlay(BOOL demo, NSString *slot) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath()];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    if ([config[slot] isKindOfClass:NSString.class]) [candidates addObject:[NSURL fileURLWithPath:config[slot]]];
    NSString *identifier = demo ? @MIRAGE_DEMO_BUNDLE_ID : @MIRAGE_FULL_BUNDLE_ID;
    NSString *name = demo ? @"PXPlay_Demo.app" : @"PXPlay.app";
    [candidates addObject:[NSURL fileURLWithPath:[@"/Applications" stringByAppendingPathComponent:name]]];
    [candidates addObject:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
        [@"Applications" stringByAppendingPathComponent:name]]]];
    [candidates addObjectsFromArray:[NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:identifier]];
    for (NSURL *candidate in candidates) {
        // Never a copy in the Trash or one nested inside another app's bundle.
        NSString *path = candidate.URLByResolvingSymlinksInPath.path;
        if ([path containsString:@"/.Trash"] || [path containsString:@".app/Contents/"]) continue;
        if (!problemWith(candidate, demo)) {
            if (![candidate.path isEqualToString:config[slot]]) remember(candidate, slot);
            return candidate;
        }
    }
    return nil;
}

static NSURL *askForPXPlay(BOOL demo, NSString *slot) {
    while (YES) {
        NSModalResponse choice = ask(T(@"launcher.notFound.title"), T(@"launcher.notFound.message"),
            @[T(@"launcher.notFound.choose"), T(@"launcher.notFound.download"), T(@"launcher.cancel")]);
        if (choice == NSAlertSecondButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                @"https://github.com/streamingdv/PSPlay-Application-Hosting/releases/tag/v3.2.0_v9.0.0"]];
            return nil;
        }
        if (choice != NSAlertFirstButtonReturn) return nil;
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
        panel.allowedContentTypes = @[UTTypeApplicationBundle];
        panel.treatsFilePackagesAsDirectories = NO;
        if ([panel runModal] != NSModalResponseOK || !panel.URL) return nil;
        NSString *problem = problemWith(panel.URL, demo);
        if (!problem) {
            remember(panel.URL, slot);
            return panel.URL;
        }
        ask(panel.URL.lastPathComponent, problem, @[@"OK"]);
    }
}

#pragma mark - Launch

static BOOL quitRunningCopies(NSString *identifier) {
    NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
    if (!running.count) return YES;
    NSModalResponse choice = ask(T(@"launcher.running.title"), T(@"launcher.running.message"),
        @[T(@"launcher.running.quit"), T(@"launcher.cancel")]);
    if (choice != NSAlertFirstButtonReturn) return NO;
    for (NSRunningApplication *app in running) [app terminate];
    for (int i = 0; i < 100; ++i) {
        BOOL alive = NO;
        for (NSRunningApplication *app in running) alive |= !app.terminated;
        if (!alive) return YES;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return NO;
}

static NSString *prepareLog(BOOL demo) {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Mirage for PXPlay"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:NULL];
    NSString *log = [folder stringByAppendingPathComponent:demo ? @"PXPlay Demo.log" : @"PXPlay.log"];
    NSString *previous = [folder stringByAppendingPathComponent:demo ? @"PXPlay Demo (previous).log" : @"PXPlay (previous).log"];
    [NSFileManager.defaultManager removeItemAtPath:previous error:NULL];
    [NSFileManager.defaultManager moveItemAtPath:log toPath:previous error:NULL];
    return log;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        loadTexts();
        BOOL demo = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"MirageTarget"] isEqual:@"demo"];
        NSString *slot = demo ? @"demo" : @"full";
        BOOL dryRun = argc > 1 && !strcmp(argv[1], "--mirage-dry-run");
        NSString *home = homeFolder();
        NSString *agent = [home stringByAppendingPathComponent:@"lib/MirageAgent.dylib"];
        if (![NSFileManager.defaultManager isReadableFileAtPath:agent]) {
            if (dryRun) { fprintf(stderr, "agent missing: %s\n", agent.UTF8String); return 2; }
            ask(T(@"launcher.failed.title"), T(@"launcher.failed.message"), @[@"OK"]);
            return 1;
        }
        NSURL *pxplay = findPXPlay(demo, slot);
        if (!pxplay && dryRun) { fprintf(stderr, "PXPlay not found\n"); return 3; }
        if (!pxplay) pxplay = askForPXPlay(demo, slot);
        if (!pxplay) return 0;

        NSString *log = dryRun ? [home stringByAppendingPathComponent:@"dry-run.log"] : prepareLog(demo);
        NSString *escaped = [agent stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSDictionary<NSString *, NSString *> *environment = @{
            @"JAVA_TOOL_OPTIONS": [NSString stringWithFormat:@"-agentpath:\"%@\"", escaped],
            @"PXPLAY_FG_RESOURCES": [home stringByAppendingPathComponent:@"Resources/FG"],
            @"MIRAGE_HOME": home,
            @"MIRAGE_LOG": log,
        };
        if (dryRun) {
            printf("app=%s\n", pxplay.path.UTF8String);
            for (NSString *key in [environment.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                printf("%s=%s\n", key.UTF8String, environment[key].UTF8String);
            }
            return 0;
        }
        NSString *identifier = demo ? @MIRAGE_DEMO_BUNDLE_ID : @MIRAGE_FULL_BUNDLE_ID;
        if (!quitRunningCopies(identifier)) return 0;

        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.environment = environment;
        configuration.activates = YES;
        configuration.addsToRecentItems = NO;
        __block NSError *failure = nil;
        __block BOOL finished = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:pxplay configuration:configuration
            completionHandler:^(NSRunningApplication *app, NSError *error) {
                (void)app;
                failure = error;
                finished = YES;
            }];
        while (!finished) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (failure) {
            ask(T(@"launcher.failed.title"), failure.localizedDescription ?: T(@"launcher.failed.message"), @[@"OK"]);
            return 1;
        }
        return 0;
    }
}
