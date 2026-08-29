#line 1 "PullOverX.mm"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <substrate.h>

#import <roothide.h>

#import "headers.h"
#import "FBSOrientationObserver.h"
#import "FBSOrientationUpdate.h"
#import "PullOverWindow.h"
#import "POApplicationHelper.h"
#import "ContextHostManager.h"

static PullOverWindow *window;
static FBSOrientationObserver *POOrientationObserver;
static UIInterfaceOrientation POActiveInterfaceOrientation = UIInterfaceOrientationUnknown;
static UIInterfaceOrientation POLastAppliedInterfaceOrientation = UIInterfaceOrientationUnknown;

#pragma mark - Camera compatibility hooks

// iOS 16 and 17 expose the background-camera permission check through
// different FigCapture client classes.  Keep their original IMPs separate:
// the classes can coexist and must not share an original implementation.
typedef BOOL (*POCameraAccessGetterIMP)(id, SEL);
static POCameraAccessGetterIMP POOriginalApplicationStateMonitorHasBackgroundCameraAccess;
static POCameraAccessGetterIMP POOriginalSessionMonitorClientHasBackgroundCameraAccess;
typedef void (*POCameraStateUpdateIMP)(id, SEL, void *, void *);
static POCameraStateUpdateIMP POOriginalSessionMonitorUpdateClientState;

static BOOL POIsCameraCaptureProcess(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
    if ([bundleIdentifier isEqualToString:@"com.apple.cameracaptured"]) {
        return YES;
    }

    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString;
    return [processName rangeOfString:@"cameracaptured"].location != NSNotFound;
}

static BOOL POIsApplicationCameraClient(id object) {
    // iOS 18 removed clientType from FigCaptureClientApplicationStateMonitorClient.
    // The tweak is filtered into the dedicated cameracaptured service,
    // so the process identity is the reliable client discriminator there.
    if (POIsCameraCaptureProcess()) {
        return YES;
    }

    SEL clientTypeSelector = NSSelectorFromString(@"clientType");
    if (![object respondsToSelector:clientTypeSelector]) {
        return NO;
    }

    NSInteger clientType = ((NSInteger (*)(id, SEL))objc_msgSend)(object, clientTypeSelector);
    return clientType != 0 && clientType != NSNotFound;
}

static BOOL POApplicationStateMonitorHasBackgroundCameraAccess(id self, SEL _cmd) {
    if (POIsApplicationCameraClient(self)) {
        return YES;
    }
    return POOriginalApplicationStateMonitorHasBackgroundCameraAccess
        ? POOriginalApplicationStateMonitorHasBackgroundCameraAccess(self, _cmd)
        : NO;
}

static BOOL POSessionMonitorClientHasBackgroundCameraAccess(id self, SEL _cmd) {
    if (POIsApplicationCameraClient(self)) {
        return YES;
    }
    return POOriginalSessionMonitorClientHasBackgroundCameraAccess
        ? POOriginalSessionMonitorClientHasBackgroundCameraAccess(self, _cmd)
        : NO;
}

static BOOL POCanHookCameraMethod(Class targetClass, SEL selector, unsigned int argumentCount) {
    Method method = targetClass ? class_getInstanceMethod(targetClass, selector) : NULL;
    return method && method_getNumberOfArguments(method) == argumentCount;
}

static void POSessionMonitorUpdateClientState(id self, SEL _cmd, void *condition, void *newValue) {
    // iOS 15's mediaserverd uses this state transition to revoke the
    // capture session when the client is not considered part of the active
    // home-screen layout.  Keeping the transition from being applied keeps
    // the camera session alive while PullOver is visible.
    (void)self;
    (void)_cmd;
    (void)condition;
    (void)newValue;
}

static __attribute__((constructor)) void POInstallCameraCompatibilityHooks(void) {
    @synchronized ([NSProcessInfo class]) {
        Class applicationStateMonitorClient = objc_getClass("FigCaptureClientApplicationStateMonitorClient");
        SEL hasBackgroundCameraAccess = @selector(hasBackgroundCameraAccess);
        if (POCanHookCameraMethod(applicationStateMonitorClient, hasBackgroundCameraAccess, 2)) {
            MSHookMessageEx(applicationStateMonitorClient,
                            hasBackgroundCameraAccess,
                            (IMP)POApplicationStateMonitorHasBackgroundCameraAccess,
                            (IMP *)&POOriginalApplicationStateMonitorHasBackgroundCameraAccess);
        }

        Class sessionMonitorClient = objc_getClass("FigCaptureClientSessionMonitorClient");
        if (POCanHookCameraMethod(sessionMonitorClient, hasBackgroundCameraAccess, 2)) {
            MSHookMessageEx(sessionMonitorClient,
                            hasBackgroundCameraAccess,
                            (IMP)POSessionMonitorClientHasBackgroundCameraAccess,
                            (IMP *)&POOriginalSessionMonitorClientHasBackgroundCameraAccess);
        }

        Class sessionMonitor = objc_getClass("FigCaptureClientSessionMonitor");
        SEL updateClientState = NSSelectorFromString(@"_updateClientStateCondition:newValue:");
        NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
        if (version.majorVersion == 15 &&
            POCanHookCameraMethod(sessionMonitor, updateClientState, 4)) {
            MSHookMessageEx(sessionMonitor,
                            updateClientState,
                            (IMP)POSessionMonitorUpdateClientState,
                            (IMP *)&POOriginalSessionMonitorUpdateClientState);
        }

    }
}

static CFStringRef const kPOSettingsChangedNotification = CFSTR("com.mlgm.pulloverx.settings-changed");

static BOOL POSettingsEnabled(NSDictionary *settings) {
    id enabled = settings[@"enabled"];
    return enabled == nil || [enabled boolValue];
}

static BOOL POIsConcreteInterfaceOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientation POResolvedInterfaceOrientation(UIInterfaceOrientation fallback) {
    if (POOrientationObserver &&
        [POOrientationObserver respondsToSelector:@selector(activeInterfaceOrientation)]) {
        UIInterfaceOrientation observed =
            (UIInterfaceOrientation)[POOrientationObserver activeInterfaceOrientation];
        if (POIsConcreteInterfaceOrientation(observed)) {
            POActiveInterfaceOrientation = observed;
        }
    }
    if (POIsConcreteInterfaceOrientation(POActiveInterfaceOrientation)) {
        return POActiveInterfaceOrientation;
    }
    if (POIsConcreteInterfaceOrientation(fallback)) {
        return fallback;
    }
    UIWindowScene *scene = window.windowScene;
    if (scene && POIsConcreteInterfaceOrientation(scene.interfaceOrientation)) {
        return scene.interfaceOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

static void POApplyInterfaceOrientation(UIInterfaceOrientation orientation,
                                        NSTimeInterval duration,
                                        BOOL forceWindowRotation) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            POApplyInterfaceOrientation(orientation, duration, forceWindowRotation);
        });
        return;
    }
    if (!POIsConcreteInterfaceOrientation(orientation)) {
        return;
    }

    BOOL orientationChanged = POLastAppliedInterfaceOrientation != orientation;
    POActiveInterfaceOrientation = orientation;
    if (!window) {
        return;
    }

    NSDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)) {
        return;
    }

    BOOL shouldHideInLandscape = [settings[@"hideInLandscape"] boolValue] &&
        UIInterfaceOrientationIsLandscape(orientation);
    // 仅清理快捷菜单等临时 UI；不再依赖“先关后开”。展开态会随窗口旋转连续重布局。
    if (orientationChanged ||
        (shouldHideInLandscape && window.rootViewController.view.alpha > 0.01)) {
        [window.controller prepareForOrientationChange];
    }

    if (shouldHideInLandscape) {
        [UIView animateWithDuration:MIN(0.2, MAX(0, duration)) animations:^{
            window.rootViewController.view.alpha = 0;
        }];
    }

    BOOL didApply = [window applyInterfaceOrientation:orientation
                                             duration:duration
                                                force:forceWindowRotation];
    if (didApply) {
        POLastAppliedInterfaceOrientation = orientation;
    }

    if (!shouldHideInLandscape) {
        [UIView animateWithDuration:MIN(0.2, MAX(0, duration)) animations:^{
            window.rootViewController.view.alpha = 1;
        }];
        // applyInterfaceOrientation 内已 layout；这里再请求一次，确保 alpha 恢复后几何稳定。
        [window requestLayoutFromCurrentScene];
    }
}

static void POStartOrientationObserver(void) {
    if (POOrientationObserver) {
        return;
    }

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    if (!observerClass) {
        return;
    }

    POOrientationObserver = [[observerClass alloc] init];
    if (!POOrientationObserver) {
        return;
    }

    UIInterfaceOrientation initialOrientation =
        (UIInterfaceOrientation)[POOrientationObserver activeInterfaceOrientation];
    if (POIsConcreteInterfaceOrientation(initialOrientation)) {
        POActiveInterfaceOrientation = initialOrientation;
    }

    [POOrientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
        if (![orientationUpdate respondsToSelector:@selector(orientation)] ||
            ![orientationUpdate respondsToSelector:@selector(duration)]) {
            return;
        }
        UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)orientationUpdate.orientation;
        if (!POIsConcreteInterfaceOrientation(orientation)) {
            return;
        }
        NSTimeInterval duration = MAX(0, orientationUpdate.duration);
        dispatch_async(dispatch_get_main_queue(), ^{
            POActiveInterfaceOrientation = orientation;
            POApplyInterfaceOrientation(orientation, duration, NO);
        });
    }];
}

static void POApplyCurrentSettings(void) {
    NSDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)) {
        if (window) {
            [window.controller prepareForOrientationChange];
            window.hidden = YES;
        }
        return;
    }

    if (!window) {
        window = [PullOverWindow sharedWindow];
        window.alpha = 1;
        [window makeKeyAndVisible];
    } else if (window.hidden) {
        window.alpha = 1;
        window.hidden = NO;
        [window makeKeyAndVisible];
    }

    window.transform = [settings[@"leftHanded"] boolValue]
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    [window.controller applyCurrentSettings];

    // 1.96: 处理 pending URL (启动时已收到但窗口未就绪)
    static dispatch_once_t pendingURLProcessed;
    NSString *pendingURL = settings[@"pendingIncomingURL"];
    if (pendingURL.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:pendingURL];
            if (url && window.controller) {
                [window.controller handleIncomingURL:url];
            }
            [POApplicationHelper setSetting:nil forKey:@"pendingIncomingURL"];
        });
    }

    UIInterfaceOrientation orientation =
        POResolvedInterfaceOrientation(UIInterfaceOrientationUnknown);
    POApplyInterfaceOrientation(orientation, 0, POLastAppliedInterfaceOrientation != orientation);
}

static void POSettingsDidChange(CFNotificationCenterRef __unused center,
                                void * __unused observer,
                                CFStringRef __unused name,
                                const void * __unused object,
                                CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        POApplyCurrentSettings();
    });
}

// The project keeps the Substrate bridge in this Objective-C++ file instead of
// running a Logos preprocessing step. These two qualifiers preserve the ABI
// that the original Logos-generated hooks used under ARC.
#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_CONST const
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif

__asm__(".linker_option \"-framework\", \"CydiaSubstrate\"");

#pragma mark - Substrate hook declarations

@class FBScene;
@class SBHomeHardwareButton;
@class SBLockHardwareButton;
@class UIMutableApplicationSceneSettings;
@class SBLockStateAggregator;
@class SBLockScreenViewControllerBase;
@class SpringBoard;
@class SBFluidSwitcherGestureManager;
@class SBBulletinBannerController;
@class BBBulletin;
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void (
    *_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void (*_logos_orig$_ungrouped$SpringBoard$takeScreenshot)(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                 SEL);
static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                SEL);
static void (*_logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$)(
    _LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase *_LOGOS_SELF_CONST, SEL, int);
static void _logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(
    _LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase *_LOGOS_SELF_CONST, SEL, int);
static void (*_logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$)(
    _LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager *_LOGOS_SELF_CONST, SEL, id, double, double);
static void _logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(
    _LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager *_LOGOS_SELF_CONST, SEL, id, double, double);
static void (*_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$)(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void (*_logos_orig$_ungrouped$SBLockHardwareButton$singlePress$)(
    _LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void _logos_method$_ungrouped$SBLockHardwareButton$singlePress$(
    _LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void (*_logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState)(
    _LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator *_LOGOS_SELF_CONST, SEL);
static void _logos_method$_ungrouped$SBLockStateAggregator$_updateLockState(
    _LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator *_LOGOS_SELF_CONST, SEL);

#pragma mark - Scene state hooks

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx,
    id completion) {
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager applyHostedInterfaceOrientationToSettings:mutableSettings forScene:(FBScene *)self];
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, mutableSettings,
                                                                                            ctx, completion);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx,
                                                                                    completion);
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx) {
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager applyHostedInterfaceOrientationToSettings:mutableSettings forScene:(FBScene *)self];
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, mutableSettings, ctx);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
}

#pragma mark - Application scene settings hooks

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    unsigned long long reasons) {
    if (reasons != 0) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if (!identifier && [settings respondsToSelector:@selector(identifier)]) {
            identifier = [settings identifier];
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, 0);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, reasons);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL foreground) {
    if (!foreground) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, YES);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, foreground);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL backgrounded) {
    if (backgrounded) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, NO);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, backgrounded);
}

#pragma mark - SpringBoard hooks

static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, UIApplication *arg1) {
    _logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$(self, _cmd, arg1);

    POStartOrientationObserver();

    NSUserDefaults *settingsDefaults = [POApplicationHelper settingsDefaults];
    if (![settingsDefaults objectForKey:@"enabled"]) {
        [settingsDefaults setObject:@(YES) forKey:@"enabled"];
        [settingsDefaults setObject:@(NO) forKey:@"hideInLandscape"];
        [settingsDefaults setObject:[NSArray new] forKey:@"favorites"];
        [settingsDefaults setObject:[NSNumber numberWithInt:5] forKey:@"recentAppsCount"];
        [settingsDefaults setObject:@"Recent Apps" forKey:@"style"];
        [settingsDefaults synchronize];
    }
    if (![settingsDefaults objectForKey:@"favorites"]) {
        [settingsDefaults setObject:[NSArray new] forKey:@"favorites"];
        [settingsDefaults synchronize];
    }

    // These options default to enabled, while preserving an explicit user choice.
    BOOL addedFeatureDefaults = NO;
    if (![settingsDefaults objectForKey:@"hideOnScreenshot"]) {
        [settingsDefaults setObject:@(YES) forKey:@"hideOnScreenshot"];
        addedFeatureDefaults = YES;
    }
    if (![settingsDefaults objectForKey:@"keyboardAvoiding"]) {
        [settingsDefaults setObject:@(YES) forKey:@"keyboardAvoiding"];
        addedFeatureDefaults = YES;
    }
    if (![settingsDefaults objectForKey:@"landscapeKeyboardZoom"]) {
        [settingsDefaults setObject:@(YES) forKey:@"landscapeKeyboardZoom"];
        addedFeatureDefaults = YES;
    }
    if (addedFeatureDefaults) {
        [settingsDefaults synchronize];
    }

    NSMutableDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      POApplyCurrentSettings();
    });
}

static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, long long arg1,
    double arg2, BOOL arg3, BOOL arg4, id arg5) {
    _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
        self, _cmd, arg1, arg2, arg3, arg4, arg5);

    UIInterfaceOrientation orientation = POResolvedInterfaceOrientation((UIInterfaceOrientation)arg1);
    POApplyInterfaceOrientation(orientation, MAX(0, arg2), YES);
}

static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
    BOOL enabled = [[POApplicationHelper settings][@"hideOnScreenshot"] boolValue];
    POHandle *handle = window.controller.handle;
    if (handle && enabled && !handle.hidden) {
        CGFloat previousAlpha = handle.alpha;
        handle.hidden = YES;
        handle.alpha = 0;

        [CATransaction flush];
        _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          handle.hidden = NO;
          handle.alpha = previousAlpha;
        });
        return;
    }
    _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
}

#pragma mark - Hardware and lock-state hooks

static void _logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(
    _LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    int arg1) {
    _logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(self, _cmd, arg1);
}

static void _logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(
    _LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1,
    double arg2, double arg3) {
    if ([window.controller isOpened]) {
        [window.controller close];
        [self grabberTongueCanceledPulling:arg1 withDistance:arg2 andVelocity:arg3];
    } else {
        _logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(
            self, _cmd, arg1, arg2, arg3);
    }
}

static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1) {
    if ([window.controller isOpened]) {
        [window.controller close];
    } else {
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
    }
}

static void _logos_method$_ungrouped$SBLockHardwareButton$singlePress$(
    _LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1) {
    if ([window.controller isOpened]) {
        [window.controller close];
    }
    _logos_orig$_ungrouped$SBLockHardwareButton$singlePress$(self, _cmd, arg1);
}

static void _logos_method$_ungrouped$SBLockStateAggregator$_updateLockState(
    _LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
    _logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState(self, _cmd);
    if ([self valueForKey:@"_lockState"]) {
        unsigned long long o = [[self valueForKey:@"_lockState"] longLongValue];
        if (o == 0) {
            [UIView animateWithDuration:0.2
                             animations:^{
                               if (window) {
                                   window.alpha = 1;
                               }
                             }];
        } else {
            [UIView animateWithDuration:0.2
                             animations:^{
                               if (window) {
                                   window.alpha = 0;
                               }
                             }];
        }
    }
}

#pragma mark - URL scheme handling (1.96)

// 1.96: SpringBoard 收到 pulloverx:// URL 时调用我们的 handler
// Hook SpringBoard 的 openURL: 方法 (NSURL 版) — PullOverX 接管 pulloverx:// scheme
static void (*_logos_orig$_ungrouped$SpringBoard$_openURL)(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, NSURL *);
static void _logos_method$_ungrouped$SpringBoard$_openURL(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, NSURL *url) {
    if ([url isKindOfClass:NSURL.class]) {
        NSString *scheme = url.scheme.lowercaseString ?: @"";
        if ([scheme isEqualToString:@"pulloverx"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (window && window.controller) {
                    [window.controller handleIncomingURL:url];
                } else {
                    NSLog(@"[PullOverX] SpringBoard openURL: window not ready, storing URL");
                    [POApplicationHelper setSetting:url.absoluteString forKey:@"pendingIncomingURL"];
                }
            });
            return;  // 拦截, 不传递给系统
        }
    }
    if (_logos_orig$_ungrouped$SpringBoard$_openURL) {
        _logos_orig$_ungrouped$SpringBoard$_openURL(self, _cmd, url);
    }
}

// 1.96: 通知横幅窗口化 — 横幅来的时候拿到来源 app (bulletin.sectionID), 交给 controller 开小窗
typedef void (*_logos_banner_orig_type)(_LOGOS_SELF_TYPE_NORMAL SBBulletinBannerController *_LOGOS_SELF_CONST, SEL, id, id, unsigned long long, id);
static _logos_banner_orig_type _logos_orig$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$;
static void _logos_method$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$(
    _LOGOS_SELF_TYPE_NORMAL SBBulletinBannerController *_LOGOS_SELF_CONST __unused self,
    SEL __unused _cmd, id observer, id bulletin, unsigned long long feed, id reply) {
    // 先让系统正常展示横幅
    if (_logos_orig$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$) {
        _logos_orig$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$(self, _cmd, observer, bulletin, feed, reply);
    }
    // 取来源 app: BBBulletin.sectionID == app bundleID
    if (![bulletin isKindOfClass:NSClassFromString(@"BBBulletin")]) {
        // 有些 iOS 版本不是直接传 BBBulletin, 尝试 KVC
        if ([bulletin respondsToSelector:@selector(sectionID)]) {
            NSString *sectionID = [bulletin valueForKey:@"sectionID"];
            if (sectionID.length > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (window && window.controller) {
                        [window.controller pinAppFromNotificationWithSectionID:sectionID];
                    }
                });
            }
        }
        return;
    }
    NSString *sectionID = [bulletin valueForKey:@"sectionID"];
    if (sectionID.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (window && window.controller) {
                [window.controller pinAppFromNotificationWithSectionID:sectionID];
            }
        });
    }
}

#pragma mark - Hook registration

static __attribute__((constructor)) void POInstallSpringBoardHooks(int __unused argc, char __unused **argv,
                                                                    char __unused **envp) {
    if (!objc_getClass("SpringBoard")) {
        return;
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, POSettingsDidChange,
                                    kPOSettingsChangedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    {
        Class _logos_class$_ungrouped$FBScene = objc_getClass("FBScene");
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene,
                            @selector(updateSettings:withTransitionContext:completion:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene, @selector(updateSettings:withTransitionContext:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$);
        }
        Class _logos_class$_ungrouped$UIMutableApplicationSceneSettings =
            objc_getClass("UIMutableApplicationSceneSettings");
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings,
                            @selector(setDeactivationReasons:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setForeground:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setBackgrounded:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$);
        }
        Class _logos_class$_ungrouped$SpringBoard = objc_getClass("SpringBoard");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(applicationDidFinishLaunching:),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$);
        }
        {
            MSHookMessageEx(
                _logos_class$_ungrouped$SpringBoard,
                @selector(noteInterfaceOrientationChanged:duration:updateMirroredDisplays:force:logMessage:),
                (IMP)&_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$,
                (IMP *)&_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(takeScreenshot),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$takeScreenshot,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$takeScreenshot);
        }
        Class _logos_class$_ungrouped$SBLockScreenViewControllerBase = objc_getClass("SBLockScreenViewControllerBase");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBLockScreenViewControllerBase,
                            @selector(finishUIUnlockFromSource:),
                            (IMP)&_logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$,
                            (IMP *)&_logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$);
        }
        Class _logos_class$_ungrouped$SBFluidSwitcherGestureManager = objc_getClass("SBFluidSwitcherGestureManager");
        {
            MSHookMessageEx(
                _logos_class$_ungrouped$SBFluidSwitcherGestureManager,
                @selector(grabberTongueBeganPulling:withDistance:andVelocity:),
                (IMP)&_logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$,
                (IMP *)&_logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$);
        }
        Class _logos_class$_ungrouped$SBHomeHardwareButton = objc_getClass("SBHomeHardwareButton");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBHomeHardwareButton, @selector(singlePressUp:),
                            (IMP)&_logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$,
                            (IMP *)&_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$);
        }
        Class _logos_class$_ungrouped$SBLockHardwareButton = objc_getClass("SBLockHardwareButton");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBLockHardwareButton, @selector(singlePress:),
                            (IMP)&_logos_method$_ungrouped$SBLockHardwareButton$singlePress$,
                            (IMP *)&_logos_orig$_ungrouped$SBLockHardwareButton$singlePress$);
        }
        Class _logos_class$_ungrouped$SBLockStateAggregator = objc_getClass("SBLockStateAggregator");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBLockStateAggregator, @selector(_updateLockState),
                            (IMP)&_logos_method$_ungrouped$SBLockStateAggregator$_updateLockState,
                            (IMP *)&_logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState);
        }
        // 1.96: 注册 SpringBoard URL hooks - pulloverx:// scheme
        {
            SEL openURLSel = @selector(openURL:);
            Method openURLMethod = class_getInstanceMethod(_logos_class$_ungrouped$SpringBoard, openURLSel);
            if (openURLMethod) {
                MSHookMessageEx(_logos_class$_ungrouped$SpringBoard,
                                openURLSel,
                                (IMP)&_logos_method$_ungrouped$SpringBoard$_openURL,
                                (IMP *)&_logos_orig$_ungrouped$SpringBoard$_openURL);
                NSLog(@"[PullOverX] Hooked SpringBoard openURL:");
            } else {
                NSLog(@"[PullOverX] SpringBoard openURL: not found");
            }
        }
        // 1.96: 通知横幅窗口化 hook - 横幅来时把来源 app pin 进小窗
        {
            Class bannerController = NSClassFromString(@"SBBulletinBannerController");
            if (bannerController) {
                SEL bannerSel = @selector(observer:addBulletin:forFeed:playLightsAndSirens:withReply:);
                Method bannerMethod = class_getInstanceMethod(bannerController, bannerSel);
                if (bannerMethod) {
                    MSHookMessageEx(bannerController,
                                    bannerSel,
                                    (IMP)&_logos_method$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$,
                                    (IMP *)&_logos_orig$_ungrouped$SBBulletinBannerController$observer$addBulletin$forFeed$playLightsAndSirens$withReply$);
                    NSLog(@"[PullOverX] Hooked SBBulletinBannerController banner");
                } else {
                    NSLog(@"[PullOverX] SBBulletinBannerController selector not found");
                }
            } else {
                NSLog(@"[PullOverX] SBBulletinBannerController class not found");
            }
        }
    }
}
