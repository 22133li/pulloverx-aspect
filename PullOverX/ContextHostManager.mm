#import "ContextHostManager.h"
#import "POApplicationHelper.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

enum {
    kPOBKSProcessAssertionPreventTaskSuspend = (1 << 0),
    kPOBKSProcessAssertionPreventTaskThrottleDown = (1 << 1),
    kPOBKSProcessAssertionWantsForegroundResourcePriority = (1 << 3),
    kPOBKSProcessAssertionPreventThrottleDownUI = (1 << 5),
    kPOBKSProcessAssertionReasonBackgroundUI = 7,
};

@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(int)pid;
@end

@interface RBSLegacyAttribute : NSObject
+ (instancetype)attributeWithReason:(NSUInteger)reason flags:(NSUInteger)flags;
@end

@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation target:(id)target attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@end

// 在当前视图中承载已挂起应用的实时场景。
// On iOS 13 and later, FBSceneHostManager no longer exposes the application's
// rendered scene reliably. The working path is the scene's layer manager and
// _UIContextLayerHostView.
static NSString * const kPORequester = @"com.mlgm.pulloverx";


static SBApplication *applicationForID(NSString *applicationID);
#if DEBUG
#define POHostDebugLog(format, ...) NSLog(@"[PullOverX Host] " format, ##__VA_ARGS__)

static void POLogSceneStateSelectors(id settings) {
    static NSMutableSet<NSString *> *loggedClasses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loggedClasses = [NSMutableSet set];
    });

    Class settingsClass = [settings class];
    NSString *className = NSStringFromClass(settingsClass);
    if (!settingsClass || [loggedClasses containsObject:className]) {
        return;
    }
    [loggedClasses addObject:className];

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(settingsClass, &methodCount);
    NSMutableArray<NSString *> *stateSelectors = [NSMutableArray array];
    for (unsigned int index = 0; methods && index < methodCount; index++) {
        NSString *selectorName = NSStringFromSelector(method_getName(methods[index]));
        NSString *lowercaseName = selectorName.lowercaseString;
        if ([lowercaseName containsString:@"foreground"] ||
            [lowercaseName containsString:@"background"] ||
            [lowercaseName containsString:@"activation"] ||
            [lowercaseName containsString:@"active"] ||
            [lowercaseName containsString:@"occlud"]) {
            [stateSelectors addObject:selectorName];
        }
    }
    free(methods);
    POHostDebugLog(@"Scene settings %@ state selectors: %@", className, stateSelectors);
}
#else
#define POHostDebugLog(format, ...)
#endif

@interface ContextHostManager ()
@property (nonatomic, strong) FBScene *hostedScene;
@property (nonatomic, strong) FBSceneLayerManager *hostedLayerManager;
@property (nonatomic, strong) FBSceneHostManager *hostedFallbackHostManager;
@property (nonatomic, copy) NSString *hostedBundleId;
@property (nonatomic, copy) NSString *launchRequestedBundleId;
@property (nonatomic, assign) BOOL observingLayers;
@property (nonatomic, assign) BOOL hasPublishedSceneStack;
@property (nonatomic, strong) id processAssertion;
@property (nonatomic, strong) dispatch_source_t keepAliveTimer;
- (void)startKeepAliveForBundleId:(NSString *)bundleId;
- (void)stopKeepAlive;
- (void)acquireProcessAssertionForBundleId:(NSString *)bundleId;
- (void)releaseProcessAssertion;
- (int)pidForBundleId:(NSString *)bundleId;
@end

@implementation ContextHostManager

#pragma mark - public methods
+ (id)sharedInstance{
    static dispatch_once_t onceToken;
    static ContextHostManager *sharedInstance = nil;
    dispatch_once(&onceToken, ^{
        sharedInstance = [ContextHostManager new];
    });
    return sharedInstance;
}

+ (NSString *)activeHostedBundleId{
    return [[self sharedInstance] hostedBundleId];
}

- (NSString *)activeHostedBundleId{
    return self.hostedBundleId;
}

+ (BOOL)shouldKeepForegroundForIdentifier:(NSString *)identifier{
    if (identifier.length == 0) {
        return NO;
    }
    NSString *bundleId = [self activeHostedBundleId];
    if (bundleId.length == 0) {
        return NO;
    }
    // 精确匹配，避免子串误判：如 com.tencent 会误配 com.tencent.xin，把不该保活
    // 的应用锁在前台。identifier 可能是纯 bundleId，或场景标识 sceneID:<bundleId>-<UUID>。
    // 后者要求 bundleId 之后紧跟 '-'，防止 com.a.mm 误配 com.a.mmpro。
    if ([identifier isEqualToString:bundleId]) {
        return YES;
    }
    NSString *scenePrefix = [bundleId stringByAppendingString:@"-"];
    NSRange range = [identifier rangeOfString:scenePrefix];
    if (range.location == NSNotFound) {
        return NO;
    }
    // bundleId 前必须是字符串开头或 ':'（sceneID: 前缀），确保是完整 bundleId 边界。
    if (range.location == 0) {
        return YES;
    }
    unichar before = [identifier characterAtIndex:range.location - 1];
    return before == ':';
}

+ (BOOL)shouldKeepForegroundForScene:(FBScene *)scene{
    if (!scene) {
        return NO;
    }
    ContextHostManager *manager = [self sharedInstance];
    if (manager.hostedScene == scene) {
        return YES;
    }
    NSString *identifier = nil;
    if ([scene respondsToSelector:@selector(identifier)]) {
        identifier = [scene identifier];
    }
    return [self shouldKeepForegroundForIdentifier:identifier];
}


-(UIView *)hostViewForBundleID:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return nil;
    }

    BOOL isNewRequest = ![self.hostedBundleId isEqualToString:bundleId];
    if (isNewRequest) {
        // 新请求尚未有场景时，旧场景的异步图层回调不能继续发布到新面板。
        // 旧应用仍由控制器保留为可见内容，待新场景实际出现后再转入后台。
        [self stopKeepAlive];
        [self releaseProcessAssertion];
        [self stopObservingLayerManager];
        if (self.hostedFallbackHostManager) {
            [self.hostedFallbackHostManager disableHostingForRequester:kPORequester];
        }
        self.hostedScene = nil;
        self.hostedLayerManager = nil;
        self.hostedFallbackHostManager = nil;
        self.hostedBundleId = [bundleId copy];
        self.launchRequestedBundleId = nil;
        self.hasPublishedSceneStack = NO;
    }

    // 冷启动只请求一次。反复以 suspended 方式启动同一应用会打断其场景创建，
    // 是冷启动偶发白屏的重要来源；后续轮询只等待场景和图层就绪。
    if (![self.launchRequestedBundleId isEqualToString:bundleId]) {
        [self launchSuspendedApplicationWithBundleID:bundleId];
        self.launchRequestedBundleId = [bundleId copy];
    }

    FBScene *scene = [self sceneForBundleId:bundleId];
    if (!scene) {
        return nil;
    }

    BOOL sceneChanged = self.hostedScene != scene;
    self.hostedScene = scene;
    if (sceneChanged || ![self.hostedBundleId isEqualToString:bundleId]) {
        self.hostedBundleId = [bundleId copy];
        [self setForeground:YES forScene:scene];
        [self acquireProcessAssertionForBundleId:bundleId];
        [self startKeepAliveForBundleId:bundleId];
    } else {
        // Re-assert even if the same scene is reused; camera checks can race after backgrounding.
        [self setForeground:YES forScene:scene];
        [self acquireProcessAssertionForBundleId:bundleId];
        [self startKeepAliveForBundleId:bundleId];
    }

    FBSceneLayerManager *layerManager = [self layerManagerForScene:scene];
    if (layerManager) {
        [self observeLayerManager:layerManager];
        // 通过 delegate 发布当前场景栈，不在此直接返回视图。这样与 KVO 图层
        // 更新共用唯一的显示路径，避免两条路径同时重建视图导致面板闪烁。
        [self publishUpdatedSceneStacks];
        return nil;
    }

    // Retain the pre-iOS-13-style path as a fallback for systems where the
    // layer manager is not available.
    FBSceneHostManager *hostManager = [self hostManagerForScene:scene];
    if (!hostManager) {
        return nil;
    }
    [hostManager enableHostingForRequester:kPORequester orderFront:YES];
    UIView *hostView = [hostManager hostViewForRequester:kPORequester enableAndOrderFront:YES];
    if (!hostView) {
        return nil;
    }

    self.hostedFallbackHostManager = hostManager;
    self.hasPublishedSceneStack = YES;
    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if ([delegate respondsToSelector:@selector(contextManager:scene:sceneStackDidChange:)]) {
        [delegate contextManager:self scene:scene sceneStackDidChange:hostView];
    }
    return nil;
}

-(void)stopHosting{
    FBScene *scene = self.hostedScene;
    NSString *hostedId = self.hostedBundleId;
    [self stopKeepAlive];
    [self releaseProcessAssertion];
    [self stopObservingLayerManager];
    if (self.hostedFallbackHostManager) {
        [self.hostedFallbackHostManager disableHostingForRequester:kPORequester];
    }
    // 先清空托管状态再让场景退后台，否则 updateSettings hook 会把 NO 改回 YES。
    self.hostedScene = nil;
    self.hostedLayerManager = nil;
    self.hostedFallbackHostManager = nil;
    self.hostedBundleId = nil;
    self.launchRequestedBundleId = nil;
    self.hasPublishedSceneStack = NO;
    // 被托管 App 恰好是当前前台主 App 时（如在该 App 内打开面板托管它自己），
    // 绝不能设为后台，否则会把用户正在使用的前台 App 打到后台，表现为卡死。
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    BOOL hostedIsFrontmost = hostedId.length > 0 && frontId.length > 0 &&
        ([hostedId isEqualToString:frontId] || [frontId isEqualToString:hostedId]);
    if (scene && !hostedIsFrontmost) {
        [self setForeground:NO forScene:scene];
    }
}

-(void)stopHostingView:(__weak UIView *)view forBundleId:(NSString *)bundleId{
    FBScene *scene = self.hostedScene;
    if (!scene || ![self.hostedBundleId isEqualToString:bundleId]) {
        // No hosting session belongs to this bundle. In particular, do not
        // look up and background a foreground app merely because PullOver's
        // "already open" placeholder was dismissed.
        return;
    }

    [self stopHosting];
}

-(BOOL)isHostingScene:(FBScene *)scene forBundleId:(NSString *)bundleId{
    return scene != nil && scene == self.hostedScene &&
        [self.hostedBundleId isEqualToString:bundleId];
}

-(BOOL)isHostingBundleReady:(NSString *)bundleId{
    return self.hasPublishedSceneStack && self.hostedScene != nil &&
        [self.hostedBundleId isEqualToString:bundleId];
}

-(void)backgroundSceneForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    // Never background the scene we are actively hosting/observing right now.
    if ([self.hostedBundleId isEqualToString:bundleId]) {
        return;
    }
    // 也不能后台化当前前台主 App。
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 &&
        ([bundleId isEqualToString:frontId] || [frontId isEqualToString:bundleId])) {
        return;
    }
    FBScene *scene = [self sceneForBundleId:bundleId];
    if (scene) {
        [self setForeground:NO forScene:scene];
    }
}

- (BOOL)isHostViewHosting:(UIView *)hostView {
    if (!hostView) {
        return NO;
    }
    for (UIView *sub in hostView.subviews) {
        if ([sub respondsToSelector:@selector(isHosting)]) {
            return [(FBWindowContextHostView *)sub isHosting];
        }
    }
    return hostView.superview != nil && hostView.subviews.count > 0;
}


#pragma mark - scene helpers

- (FBScene *)sceneForBundleId:(NSString *)bundleId{
    Class fbm = NSClassFromString(@"FBSceneManager");
    id mgr = [fbm respondsToSelector:@selector(sharedInstance)] ? [fbm sharedInstance] : nil;
    __block FBScene *bestScene = nil;
    __block NSInteger bestScore = NSIntegerMin;
    if (mgr && [mgr respondsToSelector:@selector(enumerateScenesWithBlock:)] && bundleId) {
        [mgr enumerateScenesWithBlock:^(id scene, BOOL *stop) {
            NSString *ident = nil;
            if ([scene respondsToSelector:@selector(identifier)]) {
                ident = [scene identifier];
            }
            if (![ident containsString:bundleId]) {
                return;
            }

            // App scene identifiers begin with the bundle identifier. Prefer
            // them over auxiliary/external scenes that merely reference it.
            NSInteger score = [ident hasPrefix:[bundleId stringByAppendingString:@"-"]] ? 100 : 10;
            if ([scene respondsToSelector:@selector(isValid)] && [scene isValid]) {
                score += 10;
            }
            if ([scene respondsToSelector:@selector(isActive)] && [scene isActive]) {
                score += 5;
            }
            if (score > bestScore) {
                bestScore = score;
                bestScene = scene;
            }
        }];
    }
    if (bestScene) {
        return bestScene;
    }

    SBApplication *app = applicationForID(bundleId);
    id appObject = app;
    if ([appObject respondsToSelector:@selector(mainScene)]) {
        FBScene *s = (FBScene *)[appObject mainScene];
        if (s) return s;
    }
    if ([appObject respondsToSelector:@selector(_mainScene)]) {
        FBScene *s = (FBScene *)[appObject performSelector:@selector(_mainScene)];
        if (s) return s;
    }
    if ([appObject respondsToSelector:@selector(scene)]) {
        return (FBScene *)[appObject performSelector:@selector(scene)];
    }
    return nil;
}

- (FBSceneHostManager *)hostManagerForScene:(FBScene *)scene{
    @try {
        id hm = [scene hostManager];
        if (hm) return (FBSceneHostManager *)hm;
    } @catch (NSException *e) {
    }
    return nil;
}

- (FBSceneLayerManager *)layerManagerForScene:(FBScene *)scene{
    if (!scene) return nil;
    @try {
        if ([scene respondsToSelector:@selector(layerManager)]) {
            return [scene layerManager];
        }
        return [scene valueForKey:@"_layerManager"];
    } @catch (NSException *exception) {
        return nil;
    }
}

- (void)setForeground:(BOOL)foreground forScene:(FBScene *)scene{
    [self mutateSettingsForScene:scene withBlock:^(id settings){
#if DEBUG
        POLogSceneStateSelectors(settings);
        POHostDebugLog(@"Set foreground=%d for %@ using %@", foreground,
                       [scene respondsToSelector:@selector(identifier)] ? [scene identifier] : @"<unknown>",
                       NSStringFromClass([settings class]));
#endif
        if ([settings respondsToSelector:@selector(setForeground:)]) {
            [settings setForeground:foreground];
        }
        if ([settings respondsToSelector:@selector(setBackgrounded:)]) {
            [settings setBackgrounded:!foreground];
        }
        // Camera capture on iOS 16/17 also keys off deactivation/occlusion, not only
        // the foreground bit. Keep hosted scenes fully "active" while pinned.
        if (foreground) {
            if ([settings respondsToSelector:@selector(setDeactivationReasons:)]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, @selector(setDeactivationReasons:), 0ULL);
            }
            if ([settings respondsToSelector:@selector(setIdleModeEnabled:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, @selector(setIdleModeEnabled:), NO);
            }
            if ([settings respondsToSelector:@selector(setOccluded:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, @selector(setOccluded:), NO);
            }
            if ([settings respondsToSelector:@selector(setUnderLock:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, @selector(setUnderLock:), NO);
            }
        }
    }];
}

// 每个 scene 修改都用的 settings “读-改-写”公用方法。对 scene 可能暴露的多种
// 私有 mutable settings 退回途径都做了兼容。
- (void)mutateSettingsForScene:(FBScene *)scene withBlock:(void (^)(id settings))block{
    if (!scene || !block) return;
    @try {
        id settings = nil;
        if ([scene respondsToSelector:@selector(mutableSettings)]) {
            settings = [[scene mutableSettings] mutableCopy];
        }
        if (!settings && [scene respondsToSelector:@selector(settings)]) {
            settings = [[scene settings] mutableCopy];
        }
        if (!settings) {
            settings = [[scene valueForKey:@"_mutableSettings"] mutableCopy];
        }
        if (!settings) {
            settings = [[scene valueForKey:@"_settings"] mutableCopy];
        }
        if (!settings) {
            return;
        }
        block(settings);
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
            [scene updateSettings:settings withTransitionContext:nil completion:nil];
        } else {
            [scene updateSettings:settings withTransitionContext:nil];
        }
    } @catch (NSException *exception) {
    }
}

- (void)observeLayerManager:(FBSceneLayerManager *)layerManager{
    if (self.observingLayers && self.hostedLayerManager == layerManager) {
        return;
    }
    [self stopObservingLayerManager];
    self.hostedLayerManager = layerManager;
    @try {
        [layerManager addObserver:self forKeyPath:@"layers" options:NSKeyValueObservingOptionNew context:NULL];
        self.observingLayers = YES;
    } @catch (NSException *exception) {
    }
}

- (void)stopObservingLayerManager{
    if (!self.observingLayers || !self.hostedLayerManager) {
        self.observingLayers = NO;
        return;
    }
    @try {
        [self.hostedLayerManager removeObserver:self forKeyPath:@"layers"];
    } @catch (NSException *exception) {
    }
    self.observingLayers = NO;
}

- (UIView *)sceneStackForScene:(FBScene *)scene keyboardSceneStack:(UIView **)keyboardStackOut{
    FBSceneLayerManager *manager = [self layerManagerForScene:scene];
    NSArray *layers = nil;
    @try {
        id rawLayers = [manager layers];
        if ([rawLayers respondsToSelector:@selector(array)]) {
            layers = [rawLayers array];
        } else if ([rawLayers isKindOfClass:[NSArray class]]) {
            layers = rawLayers;
        }
    } @catch (NSException *exception) {
    }

    CGSize stackSize = CGSizeZero;
    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if ([delegate respondsToSelector:@selector(contextManagerPreferredSceneStackSize:)]) {
        stackSize = [delegate contextManagerPreferredSceneStackSize:self];
    }
    if (stackSize.width <= 0 || stackSize.height <= 0) {
        stackSize = [UIScreen mainScreen].bounds.size;
    }
    CGRect stackFrame = (CGRect){ CGPointZero, stackSize };
    UIView *sceneStack = [[UIView alloc] initWithFrame:stackFrame];
    UIView *keyboardSceneStack = [[UIView alloc] initWithFrame:stackFrame];
    for (FBSceneLayer *layer in layers) {
        @try {
            id sceneLayer = (id)layer;
            NSString *externalSceneId = [sceneLayer respondsToSelector:@selector(externalSceneID)] ? [sceneLayer externalSceneID] : nil;
            BOOL isKeyboardLayer = [sceneLayer respondsToSelector:@selector(isKeyboardLayer)] && [sceneLayer isKeyboardLayer];
            if (isKeyboardLayer) {
                Class keyboardHostClass = objc_getClass("_UIKeyboardLayerHostView");
                _UIKeyboardLayerHostView *hostView = [[keyboardHostClass alloc] initWithKeyboardLayer:layer owningScene:scene];
                hostView.frame = keyboardSceneStack.bounds;
                [keyboardSceneStack addSubview:hostView];
            } else if (externalSceneId != nil) {
                Class externalHostClass = objc_getClass("_UIExternalSceneLayerHostView");
                _UIExternalSceneLayerHostView *hostView = [[externalHostClass alloc] initWithSceneLayer:layer parentScene:scene];
                hostView.frame = keyboardSceneStack.bounds;
                [keyboardSceneStack addSubview:hostView];
            } else {
                UIView *hostView = [[NSClassFromString(@"_UIContextLayerHostView") alloc] initWithSceneLayer:layer];
                hostView.frame = sceneStack.bounds;
                [sceneStack addSubview:hostView];
            }
        } @catch (NSException *exception) {
        }
    }


    if (keyboardStackOut) {
        *keyboardStackOut = keyboardSceneStack;
    }
    return sceneStack;
}

- (void)publishUpdatedSceneStacks{
    FBScene *scene = self.hostedScene;
    if (!scene) {
        return;
    }
    UIView *keyboardSceneStack = nil;
    UIView *sceneStack = [self sceneStackForScene:scene keyboardSceneStack:&keyboardSceneStack];
    if (sceneStack.subviews.count == 0) {
        return;
    }
    self.hasPublishedSceneStack = YES;

    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if ([delegate respondsToSelector:@selector(contextManager:scene:sceneStackDidChange:)]) {
        [delegate contextManager:self scene:scene sceneStackDidChange:sceneStack];
    }
    if (keyboardSceneStack.subviews.count > 0 && [delegate respondsToSelector:@selector(contextManager:scene:externalSceneStackDidChange:)]) {
        [delegate contextManager:self scene:scene externalSceneStackDidChange:keyboardSceneStack];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context{
    if (![keyPath isEqualToString:@"layers"] || object != self.hostedLayerManager) {
        return;
    }
    // 主线程上的 KVO 回调应立即发布场景栈。若推迟到下一轮 runloop，新的托管
    // 视图合成前会短暂显示白色背景和加载指示器。KVO 通常已在主线程送达，
    // 这里仍保留线程保护。
    if ([NSThread isMainThread]) {
        [self publishUpdatedSceneStacks];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self publishUpdatedSceneStacks];
        });
    }
}

- (void)launchSuspendedApplicationWithBundleID:(NSString *)bundleID{
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleID suspended:YES];
}

- (int)pidForBundleId:(NSString *)bundleId{
    id app = applicationForID(bundleId);
    if (!app) {
        return 0;
    }
    int pid = 0;
    @try {
        if ([app respondsToSelector:@selector(pid)]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:@selector(pid)];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(pid)];
                [inv setTarget:app];
                [inv invoke];
                [inv getReturnValue:&pid];
            }
        }
        if (pid <= 0 && [app respondsToSelector:@selector(processState)]) {
            id processState = [app performSelector:@selector(processState)];
            if ([processState respondsToSelector:@selector(pid)]) {
                NSMethodSignature *sig = [processState methodSignatureForSelector:@selector(pid)];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:@selector(pid)];
                    [inv setTarget:processState];
                    [inv invoke];
                    [inv getReturnValue:&pid];
                }
            }
        }
    } @catch (__unused NSException *exception) {
        pid = 0;
    }
    return pid;
}

- (void)acquireProcessAssertionForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    int pid = [self pidForBundleId:bundleId];
    if (pid <= 0) {
        return;
    }

    Class targetClass = NSClassFromString(@"RBSTarget");
    Class attrClass = NSClassFromString(@"RBSLegacyAttribute");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    if (!targetClass || !attrClass || !assertionClass) {
        return;
    }

    @try {
        id target = [targetClass targetWithPid:pid];
        NSUInteger flags = kPOBKSProcessAssertionPreventTaskSuspend |
            kPOBKSProcessAssertionPreventTaskThrottleDown |
            kPOBKSProcessAssertionWantsForegroundResourcePriority |
            kPOBKSProcessAssertionPreventThrottleDownUI;
        id attr = [attrClass attributeWithReason:kPOBKSProcessAssertionReasonBackgroundUI flags:flags];
        id assertion = [[assertionClass alloc] initWithExplanation:@"PullOverX keeping hosted app alive"
                                                            target:target
                                                        attributes:attr ? @[attr] : @[]];
        NSError *error = nil;
        BOOL acquired = [assertion acquireWithError:&error];
        if (acquired) {
            [self releaseProcessAssertion];
            self.processAssertion = assertion;
            POHostDebugLog(@"RBSAssertion acquired for %@ pid=%d", bundleId, pid);
        } else {
            POHostDebugLog(@"RBSAssertion failed for %@ pid=%d error=%@", bundleId, pid, error);
        }
    } @catch (NSException *exception) {
        POHostDebugLog(@"RBSAssertion exception for %@: %@", bundleId, exception);
    }
}

- (void)releaseProcessAssertion{
    id assertion = self.processAssertion;
    self.processAssertion = nil;
    if (assertion && [assertion respondsToSelector:@selector(invalidate)]) {
        @try {
            [assertion invalidate];
        } @catch (__unused NSException *exception) {
        }
    }
}

- (void)startKeepAliveForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    [self stopKeepAlive];

    __weak typeof(self) weakSelf = self;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (![strongSelf.hostedBundleId isEqualToString:bundleId]) {
            return;
        }
        // 被托管 App 就是当前前台主 App 时无需保活，且强制 setForeground:YES 可能
        // 干扰系统对前台 App 的正常管理，直接跳过。
        NSString *frontId = [POApplicationHelper frontMostBundleId];
        if (frontId.length > 0 && [bundleId isEqualToString:frontId]) {
            return;
        }
        FBScene *scene = strongSelf.hostedScene ?: [strongSelf sceneForBundleId:bundleId];
        if (!scene) {
            return;
        }
        strongSelf.hostedScene = scene;
        [strongSelf setForeground:YES forScene:scene];
        if (!strongSelf.processAssertion) {
            [strongSelf acquireProcessAssertionForBundleId:bundleId];
        }
    });
    dispatch_resume(timer);
    self.keepAliveTimer = timer;
    POHostDebugLog(@"Keep-alive started for %@", bundleId);
}

- (void)stopKeepAlive{
    dispatch_source_t timer = self.keepAliveTimer;
    self.keepAliveTimer = nil;
    if (timer) {
        dispatch_source_cancel(timer);
    }
}

static SBApplication *applicationForID(NSString *applicationID){
    id controller = [objc_getClass("SBApplicationController") sharedInstance];
    if ([controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
        return [controller applicationWithBundleIdentifier:applicationID];
    }
    if ([controller respondsToSelector:@selector(applicationWithDisplayIdentifier:)]) {
        return [controller applicationWithDisplayIdentifier:applicationID];
    }
    return nil;
}


@end
