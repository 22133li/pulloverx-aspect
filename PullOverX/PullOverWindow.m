//
//  PullOverWindow.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "PullOverWindow.h"

@interface UIWindow (PORotationPrivate)
- (void)_rotateWindowToOrientation:(long long)orientation
                   updateStatusBar:(BOOL)updateStatusBar
                          duration:(double)duration
                     skipCallbacks:(BOOL)skipCallbacks;
@end

@interface PullOverWindow ()
@property (nonatomic, assign) UIInterfaceOrientation pullOverInterfaceOrientation;
@property (nonatomic, assign) NSUInteger orientationLayoutGeneration;
- (void)applyPreferredWindowLevel;
- (void)ensureBoundToMainScene;
@end

@implementation PullOverWindow
@synthesize controller;

- (void)applyPreferredWindowLevel {
    // 主 scene 内参考：
    // SBRootSceneWindow=0（App 挂载）、SBMainSwitcherWindow=5、
    // SBStatusBarWindow=999、SBControlCenterWindow=1080。
    // 100 盖过 App，且明确低于状态栏 / 控制中心。
    // 前提是绑在 com.apple.springboard 主 scene；绑到 SystemAperture 时任何 level 都会盖过 CC。
    self.windowLevel = 100.0;
}

+ (id)sharedWindow {
    static PullOverWindow *window = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        window = [[self alloc] init];
    });
    return window;
}

+ (UIWindowScene *)activeWindowScene {
    // 必须绑定到 SpringBoard 主 scene（identifier: com.apple.springboard）。
    // 控制中心、状态栏都在这个 scene；同 scene 后 windowLevel 才可比较。
    // 不能用 foregroundActive：SystemAperture（灵动岛）也是 foregroundActive，
    // 绑到它会让 PO 整体浮在一切之上并盖过控制中心。
    UIWindowScene *springboardClassScene = nil;
    UIWindowScene *fallback = nil;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        NSString *sceneID = windowScene.session.persistentIdentifier ?: @"";
        if ([sceneID isEqualToString:@"com.apple.springboard"]) {
            return windowScene;
        }

        NSString *role = windowScene.session.role ?: @"";
        NSString *className = NSStringFromClass([windowScene class]);
        BOOL isApertureOrKeyboard =
            [sceneID rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sceneID rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [role rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [role rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [className rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (isApertureOrKeyboard) {
            continue;
        }

        // 次选：SBWindowScene（主 identifier 偶发读不到时的兜底）。
        if (!springboardClassScene && [className isEqualToString:@"SBWindowScene"]) {
            springboardClassScene = windowScene;
            continue;
        }

        if (!fallback && windowScene.activationState == UISceneActivationStateForegroundActive) {
            fallback = windowScene;
        }
    }

    return springboardClassScene ?: fallback;
}

- (void)ensureBoundToMainScene {
    UIWindowScene *mainScene = [PullOverWindow activeWindowScene];
    if (!mainScene || self.windowScene == mainScene) {
        return;
    }

    // 初始化时主 scene 可能尚未就绪，先落到 fallback；显示/布局时再纠正。
    self.windowScene = mainScene;
    CGRect bounds = mainScene.coordinateSpace.bounds;
    if (!CGRectIsEmpty(bounds)) {
        self.frame = bounds;
    }
}

- (id)init {
    UIWindowScene *scene = [PullOverWindow activeWindowScene];
    if (scene) {
        self = [super initWithWindowScene:scene];
        if (self) {
            self.frame = scene.coordinateSpace.bounds;
        }
    } else {
        self = [super initWithFrame:[UIScreen mainScreen].bounds];
    }

    if (self) {
        self.pullOverInterfaceOrientation = UIInterfaceOrientationUnknown;
        self.orientationLayoutGeneration = 0;
        [self applyPreferredWindowLevel];
        [self setHidden:NO];
        self.alpha = 1;
        self.rootViewController = controller = [[PullOverViewController alloc] init];
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (BOOL)applyInterfaceOrientation:(UIInterfaceOrientation)orientation
                         duration:(NSTimeInterval)duration
                            force:(BOOL)force {
    BOOL validOrientation = orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
    if (!validOrientation) {
        return NO;
    }

    BOOL orientationChanged = self.pullOverInterfaceOrientation != orientation;
    if (!force && !orientationChanged) {
        [self requestLayoutFromCurrentScene];
        return YES;
    }

    SEL rotateSelector = @selector(_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:);
    if (![self respondsToSelector:rotateSelector]) {
        // 旧系统没有该入口时保留 SpringBoard 原有的场景旋转行为，不能冒险伪造窗口 frame。
        [self requestLayoutFromCurrentScene];
        return NO;
    }

    self.pullOverInterfaceOrientation = orientation;
    NSTimeInterval animationDuration = MAX(0, duration);
    NSUInteger generation = ++self.orientationLayoutGeneration;

    [self _rotateWindowToOrientation:orientation
                    updateStatusBar:NO
                           duration:animationDuration
                      skipCallbacks:NO];

    // 重要：SpringBoard 对这个悬浮窗口通常保留竖屏坐标空间，不能用 bounds 宽高比
    // 判断“是否已转到横屏”。布局仍走两阶段：立即一帧 + 动画结束后再一帧。
    [self requestLayoutFromCurrentScene];

    __weak typeof(self) weakSelf = self;
    dispatch_block_t finishLayout = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.orientationLayoutGeneration) {
            return;
        }
        [strongSelf requestLayoutFromCurrentScene];
    };
    if (animationDuration > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), finishLayout);
    } else {
        dispatch_async(dispatch_get_main_queue(), finishLayout);
    }
    return YES;
}

- (void)requestLayoutFromCurrentScene {
    [self ensureBoundToMainScene];
    [self applyPreferredWindowLevel];
    // UIWindowScene 管理窗口尺寸。SpringBoard 对该悬浮窗口保留竖屏坐标，
    // 手动设置横屏 frame 会导致右侧和把手被裁剪；这里只触发布局刷新。
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self.rootViewController.view setNeedsLayout];
    [self.rootViewController.view layoutIfNeeded];
    [self.controller handleOrientationChange];
}

- (void)makeKeyAndVisible {
    [self ensureBoundToMainScene];
    [self applyPreferredWindowLevel];
    [super makeKeyAndVisible];
}

- (bool)_shouldCreateContextAsSecure {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitTestResult = [super hitTest:point withEvent:event];

    if ([controller isOpened]) {
        return hitTestResult;
    }

    POHandle *handle = controller.handle;
    if (handle) {
        // 用把手的扩大命中区（POHandle -pointInside: 已外扩到 ≥52pt）判定，
        // 而非要求触摸点精确落在把手图标上。手指略偏或长按微移时仍稳稳
        // 命中把手，不会穿透到桌面。
        CGPoint pointInHandle = [handle convertPoint:point fromView:self];
        if ([handle pointInside:pointInHandle withEvent:event]) {
            return handle;
        }
    }
    if ([hitTestResult isKindOfClass:[POHandle class]]) {
        return controller.handle;
    }
    return nil;
}

@end
