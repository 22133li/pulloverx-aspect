#line 1 "PullOverX.xm"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
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
typedef BOOL (*POCameraBoolGetterIMP)(id, SEL);

typedef struct {
    Class targetClass;
    SEL selector;
    POCameraBoolGetterIMP original;
} POCameraAccessHookRecord;

static POCameraAccessHookRecord POCameraAccessHooks[6];
static NSUInteger POCameraAccessHookCount = 0;

static POCameraBoolGetterIMP POOriginalCameraAccessGetter(id object, SEL selector) {
    Class currentClass = object_getClass(object);
    while (currentClass) {
        for (NSUInteger index = 0; index < POCameraAccessHookCount; index++) {
            POCameraAccessHookRecord *record = &POCameraAccessHooks[index];
            if (record->targetClass == currentClass && record->selector == selector) {
                return record->original;
            }
        }
        currentClass = class_getSuperclass(currentClass);
    }
    return NULL;
}

static BOOL POApplicationCameraClient(id object) {
    SEL clientTypeSelector = NSSelectorFromString(@"clientType");
    if (![object respondsToSelector:clientTypeSelector]) {
        return NO;
    }
    NSInteger clientType = ((NSInteger (*)(id, SEL))objc_msgSend)(object, clientTypeSelector);
    return clientType != 0 && clientType != NSNotFound;
}

static BOOL POHasCameraAccess(id self, SEL _cmd) {
    if (POApplicationCameraClient(self)) {
        return YES;
    }
    POCameraBoolGetterIMP original = POOriginalCameraAccessGetter(self, _cmd);
    return original ? original(self, _cmd) : NO;
}

static BOOL POCameraAccessMethodIsCompatible(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) {
        return NO;
    }
    const char *types = method_getTypeEncoding(method);
    return types && (types[0] == 'B' || types[0] == 'c' || types[0] == 'C');
}

static BOOL POCameraAccessGetterIsHooked(Class targetClass, SEL selector) {
    for (NSUInteger index = 0; index < POCameraAccessHookCount; index++) {
        POCameraAccessHookRecord *record = &POCameraAccessHooks[index];
        if (record->targetClass == targetClass && record->selector == selector) {
            return YES;
        }
    }
    return NO;
}

static void POInstallCameraAccessGetter(Class targetClass, SEL selector) {
    if (!targetClass || !selector ||
        POCameraAccessHookCount >= sizeof(POCameraAccessHooks) / sizeof(POCameraAccessHooks[0]) ||
        POCameraAccessGetterIsHooked(targetClass, selector)) {
        return;
    }

    Method method = class_getInstanceMethod(targetClass, selector);
    if (!POCameraAccessMethodIsCompatible(method)) {
        return;
    }

    POCameraAccessHookRecord *record = &POCameraAccessHooks[POCameraAccessHookCount];
    record->targetClass = targetClass;
    record->selector = selector;
    record->original = NULL;
    MSHookMessageEx(targetClass,
                    selector,
                    (IMP)POHasCameraAccess,
                    (IMP *)&record->original);
    POCameraAccessHookCount += 1;
}

static void POInstallCameraAccessHooks(void) {
    @synchronized ([NSProcessInfo class]) {
        for (NSString *className in @[
                 @"FigCaptureClientApplicationStateMonitorClient",
                 @"FigCaptureClientSessionMonitorClient"
             ]) {
            Class targetClass = objc_getClass(className.UTF8String);
            if (!targetClass) {
                continue;
            }
            for (NSString *selectorName in @[
                     @"hasBackgroundCameraAccess",
                     @"isMultitaskingCameraAccessEnabled",
                     @"isMultitaskingCameraAccessSupported"
                 ]) {
                POInstallCameraAccessGetter(targetClass,
                                            NSSelectorFromString(selectorName));
            }
        }
    }
}

static void POCameraImageDidLoad(__unused const struct mach_header *header,
                                 __unused intptr_t slide) {
    POInstallCameraAccessHooks();
}

static __attribute__((constructor)) void POCameraAccessBootstrap(void) {
    _dyld_register_func_for_add_image(POCameraImageDidLoad);
    POInstallCameraAccessHooks();

    
    for (NSNumber *delayNumber in @[@0.1, @0.5, @1.0, @2.0]) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            POInstallCameraAccessHooks();
        });
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


#include <substrate.h>
#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_TYPE_INIT __attribute__((ns_consumed))
#define _LOGOS_SELF_CONST const
#define _LOGOS_RETURN_RETAINED __attribute__((ns_returns_retained))
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif

__asm__(".linker_option \"-framework\", \"CydiaSubstrate\"");

@class FBScene; @class SBHomeHardwareButton; @class SBLockHardwareButton; @class UIMutableApplicationSceneSettings; @class SBLockStateAggregator; @class SBLockScreenViewControllerBase; @class SpringBoard; @class SBFluidSwitcherGestureManager; 
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$)(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST, SEL, id, id, id); static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST, SEL, id, id, id); static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$)(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST, SEL, id, id); static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST, SEL, id, id); static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$)(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, unsigned long long); static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, unsigned long long); static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$)(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, BOOL); static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, BOOL); static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$)(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, BOOL); static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST, SEL, BOOL); static void (*_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$)(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL, UIApplication *); static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL, UIApplication *); static void (*_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$)(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id); static void _logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id); static void (*_logos_orig$_ungrouped$SpringBoard$takeScreenshot)(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL); static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST, SEL); static void (*_logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$)(_LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase* _LOGOS_SELF_CONST, SEL, int); static void _logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(_LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase* _LOGOS_SELF_CONST, SEL, int); static void (*_logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$)(_LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager* _LOGOS_SELF_CONST, SEL, id, double, double); static void _logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(_LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager* _LOGOS_SELF_CONST, SEL, id, double, double); static void (*_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$)(_LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton* _LOGOS_SELF_CONST, SEL, id); static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(_LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton* _LOGOS_SELF_CONST, SEL, id); static void (*_logos_orig$_ungrouped$SBLockHardwareButton$singlePress$)(_LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton* _LOGOS_SELF_CONST, SEL, id); static void _logos_method$_ungrouped$SBLockHardwareButton$singlePress$(_LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton* _LOGOS_SELF_CONST, SEL, id); static void (*_logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState)(_LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator* _LOGOS_SELF_CONST, SEL); static void _logos_method$_ungrouped$SBLockStateAggregator$_updateLockState(_LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator* _LOGOS_SELF_CONST, SEL); 

#line 320 "PullOverX.xm"

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx, id completion) {
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
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, mutableSettings, ctx, completion);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx, completion);
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(_LOGOS_SELF_TYPE_NORMAL FBScene* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx) {
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
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, mutableSettings, ctx);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
}




static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, unsigned long long reasons){
    if (reasons != 0) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in @[@"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier"]) {
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

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, BOOL foreground){
    if (!foreground) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in @[@"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier"]) {
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

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(_LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, BOOL backgrounded){
    if (backgrounded) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in @[@"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier"]) {
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




static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, UIApplication * arg1){
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

    NSMutableDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)){
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        POApplyCurrentSettings();
    });
}





static void _logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, long long arg1, double arg2, BOOL arg3, BOOL arg4, id arg5) {
    _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(self, _cmd, arg1, arg2, arg3, arg4, arg5);

    
    
    UIInterfaceOrientation orientation =
        POResolvedInterfaceOrientation((UIInterfaceOrientation)arg1);
    POApplyInterfaceOrientation(orientation, MAX(0, arg2), YES);
}

static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(_LOGOS_SELF_TYPE_NORMAL SpringBoard* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd){
    BOOL enabled = [[POApplicationHelper settings][@"hideOnScreenshot"] boolValue];
    POHandle *handle = window.controller.handle;
    if (handle && enabled && !handle.hidden){
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




static void _logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(_LOGOS_SELF_TYPE_NORMAL SBLockScreenViewControllerBase* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, int arg1){
    _logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$(self, _cmd, arg1);
}






static void _logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(_LOGOS_SELF_TYPE_NORMAL SBFluidSwitcherGestureManager* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1, double arg2, double arg3) {
    if ([window.controller isOpened]){
        [window.controller close];
        [self grabberTongueCanceledPulling:arg1 withDistance:arg2 andVelocity:arg3];
    }else{
        _logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$(self, _cmd, arg1, arg2, arg3);
    }
}




static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(_LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1){
    if ([window.controller isOpened]){
        [window.controller close];
    }else{
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
    }
}




static void _logos_method$_ungrouped$SBLockHardwareButton$singlePress$(_LOGOS_SELF_TYPE_NORMAL SBLockHardwareButton* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1){
    if ([window.controller isOpened]){
        [window.controller close];
    }
    _logos_orig$_ungrouped$SBLockHardwareButton$singlePress$(self, _cmd, arg1);
}




static void _logos_method$_ungrouped$SBLockStateAggregator$_updateLockState(_LOGOS_SELF_TYPE_NORMAL SBLockStateAggregator* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd){
    _logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState(self, _cmd);
    if ([self valueForKey:@"_lockState"]){
        unsigned long long o = [[self valueForKey:@"_lockState"] longLongValue];
        if (o == 0){
            [UIView animateWithDuration:0.2 animations:^{
                if (window){
                    window.alpha = 1;
                }
            }];
        }else{
            [UIView animateWithDuration:0.2 animations:^{
                if (window){
                    window.alpha = 0;
                }
            }];
        }
    }
}



static __attribute__((constructor)) void _logosLocalCtor_5d17dcaa(int __unused argc, char __unused **argv, char __unused **envp) {
    if (!objc_getClass("SpringBoard")) {
        return;
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    POSettingsDidChange,
                                    kPOSettingsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    {Class _logos_class$_ungrouped$FBScene = objc_getClass("FBScene"); { MSHookMessageEx(_logos_class$_ungrouped$FBScene, @selector(updateSettings:withTransitionContext:completion:), (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$, (IMP*)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$);}{ MSHookMessageEx(_logos_class$_ungrouped$FBScene, @selector(updateSettings:withTransitionContext:), (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$, (IMP*)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$);}Class _logos_class$_ungrouped$UIMutableApplicationSceneSettings = objc_getClass("UIMutableApplicationSceneSettings"); { MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setDeactivationReasons:), (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$, (IMP*)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$);}{ MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setForeground:), (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$, (IMP*)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$);}{ MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setBackgrounded:), (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$, (IMP*)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$);}Class _logos_class$_ungrouped$SpringBoard = objc_getClass("SpringBoard"); { MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(applicationDidFinishLaunching:), (IMP)&_logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$, (IMP*)&_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$);}{ MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(noteInterfaceOrientationChanged:duration:updateMirroredDisplays:force:logMessage:), (IMP)&_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$, (IMP*)&_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$);}{ MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(takeScreenshot), (IMP)&_logos_method$_ungrouped$SpringBoard$takeScreenshot, (IMP*)&_logos_orig$_ungrouped$SpringBoard$takeScreenshot);}Class _logos_class$_ungrouped$SBLockScreenViewControllerBase = objc_getClass("SBLockScreenViewControllerBase"); { MSHookMessageEx(_logos_class$_ungrouped$SBLockScreenViewControllerBase, @selector(finishUIUnlockFromSource:), (IMP)&_logos_method$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$, (IMP*)&_logos_orig$_ungrouped$SBLockScreenViewControllerBase$finishUIUnlockFromSource$);}Class _logos_class$_ungrouped$SBFluidSwitcherGestureManager = objc_getClass("SBFluidSwitcherGestureManager"); { MSHookMessageEx(_logos_class$_ungrouped$SBFluidSwitcherGestureManager, @selector(grabberTongueBeganPulling:withDistance:andVelocity:), (IMP)&_logos_method$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$, (IMP*)&_logos_orig$_ungrouped$SBFluidSwitcherGestureManager$grabberTongueBeganPulling$withDistance$andVelocity$);}Class _logos_class$_ungrouped$SBHomeHardwareButton = objc_getClass("SBHomeHardwareButton"); { MSHookMessageEx(_logos_class$_ungrouped$SBHomeHardwareButton, @selector(singlePressUp:), (IMP)&_logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$, (IMP*)&_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$);}Class _logos_class$_ungrouped$SBLockHardwareButton = objc_getClass("SBLockHardwareButton"); { MSHookMessageEx(_logos_class$_ungrouped$SBLockHardwareButton, @selector(singlePress:), (IMP)&_logos_method$_ungrouped$SBLockHardwareButton$singlePress$, (IMP*)&_logos_orig$_ungrouped$SBLockHardwareButton$singlePress$);}Class _logos_class$_ungrouped$SBLockStateAggregator = objc_getClass("SBLockStateAggregator"); { MSHookMessageEx(_logos_class$_ungrouped$SBLockStateAggregator, @selector(_updateLockState), (IMP)&_logos_method$_ungrouped$SBLockStateAggregator$_updateLockState, (IMP*)&_logos_orig$_ungrouped$SBLockStateAggregator$_updateLockState);}}
}
