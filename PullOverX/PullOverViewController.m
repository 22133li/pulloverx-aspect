//
//  PullOverViewController.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "PullOverViewController.h"
#import "../POPPath.h"
#import "../POLocalization.h"
#define HANDLE_MARGIN 50
#define HANDLE_EDGE_GAP 5
#define CONTENT_EDGE_GAP 5
#define CONTENT_CORNER_RADIUS 20
#define CONTENT_SHADOW_OPACITY 0.28
#define CONTENT_SHADOW_FADE_DISTANCE 12.0
#define CLOSED_CONTENT_OFFSET_EPSILON 0.5
#define HOSTING_FAST_RETRY_LIMIT 12

@interface PullOverViewController ()<ContextHostManagerExternalSceneDelegate, UIGestureRecognizerDelegate>{
    NSString *pinnedBundleId;
    UIView *contextView;
    // 托管 App 的键盘/外部图层栈，只保留最新一个，关闭时释放
    UIView *externalSceneStack;
    
    UIView *dragAndDropView;
    UIImageView *dragAndDropImageView;
    UIImageView *draggableImageView;
    UILabel *dragAndDropLabel;
    UIView *shadowView;
    UITapGestureRecognizer *closeTapGestureRecognizer;
    // 无法托管时的占位画布，随卡片一起做竖转横变换
    UIView *cantHostCanvas;
    UIImageView *cantHostIconView;
    UILabel *cantHostLabel;
    
    UIActivityIndicatorView *activityIndicator;
    NSInteger hostingAttempts;
    NSString *hostingRequestBundleId;
    NSString *hostedBundleId;
    NSString *pendingBackgroundBundleId;
    BOOL hostUpdatesAllowed;
    CGPoint handlePoint;
    // chromeScale 维持把手竖向轨道；scale 是托管画布的整体缩放
    CGFloat chromeScale;
    CGFloat scale;
    CGFloat contentLayoutWidth;
    BOOL pendingOpenState;
    // 拖动结束后统一改用与点按相同的程序化滚动。该标记在滚动真正结束前
    // 阻止快捷切换菜单，避免卡片还残留在屏幕上时就被当作“已关闭”。
    BOOL scrollSnapAnimationInProgress;
    BOOL quickSwitchOpeningApp;
    BOOL showingCantHost;
    // 展开态弹出快捷菜单时，contentView 整卡平移避让菜单并保留 5pt 间隙（不改尺寸）。
    BOOL quickSwitchYieldActive;
    CGRect quickSwitchSavedContentFrame;
    CGRect quickSwitchSavedShadowFrame;
    NSNumber *origOffset;
    CGSize lastLaidOutSize;
}

@end

@implementation PullOverViewController
@synthesize scrollView, handleScrollView;

- (void)viewDidLoad {
    [super viewDidLoad];

    self.backgroundView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.backgroundView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.backgroundView.alpha = 0;
    [self.view addSubview:self.backgroundView];
    
    
    UIImage *image = [UIImage imageWithContentsOfFile:POPPath(@"/Library/Application Support/PullOverX/rocket.png")];
    
    
    dragAndDropView = [[UIView alloc] initWithFrame:CGRectMake(0,0,100,100)];
    dragAndDropView.contentMode = UIViewContentModeScaleAspectFit;
    dragAndDropView.center = CGPointMake(self.backgroundView.center.x, self.backgroundView.center.y);
    dragAndDropView.alpha = 0;
    [self.backgroundView addSubview:dragAndDropView];
    
    CAShapeLayer *border = [CAShapeLayer layer];
    border.strokeColor = [UIColor whiteColor].CGColor;
    border.fillColor = nil;
    border.lineDashPattern = @[@4, @2];
    [dragAndDropView.layer addSublayer:border];
    
    border.path = [UIBezierPath bezierPathWithRect:dragAndDropView.bounds].CGPath;
    border.frame = dragAndDropView.bounds;


    dragAndDropImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    dragAndDropImageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    dragAndDropImageView.tintColor = [UIColor whiteColor];
    dragAndDropImageView.contentMode = UIViewContentModeScaleAspectFit;
    dragAndDropImageView.center = CGPointMake(dragAndDropView.frame.size.width/2, dragAndDropView.frame.size.height/2);
    [dragAndDropView addSubview:dragAndDropImageView];
    
    
    dragAndDropLabel = [[UILabel alloc] initWithFrame:CGRectMake(0,dragAndDropView.frame.size.height+dragAndDropView.frame.origin.y+16,200, 44)];
    dragAndDropLabel.textColor = [UIColor whiteColor];
    dragAndDropLabel.textAlignment = NSTextAlignmentCenter;
    dragAndDropLabel.numberOfLines = 2;
    dragAndDropLabel.text = POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
    [self.backgroundView addSubview:dragAndDropLabel];
    dragAndDropLabel.alpha = 0;
    dragAndDropLabel.center = CGPointMake(dragAndDropView.center.x, dragAndDropLabel.center.y);
    
    
    scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [scrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [scrollView setBackgroundColor:[UIColor clearColor]];
    [scrollView setShowsHorizontalScrollIndicator:NO];
    // 安全区位置在下方统一计算，禁止 UIKit 自动追加 inset，避免刘海屏点按和拖动终点不同。
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // 横屏卡片窄于实体屏幕，UIKit 全屏分页会超出实际行程，改由拖动结束时显式吸附。
    [scrollView setPagingEnabled:NO];
    // 两端都允许 rubber-band：闭合端负向回弹触发把手收起，展开端过冲后由
    // snapPanelToOpenState: 以动画平滑收回，禁止无动画硬夹造成闪一下。
    scrollView.bounces = YES;
    scrollView.alwaysBounceHorizontal = YES;
    [scrollView setDelegate:self];
    [self.view addSubview:scrollView];
    
    closeTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    closeTapGestureRecognizer.delegate = self;
    [scrollView addGestureRecognizer:closeTapGestureRecognizer];
    
    handleScrollView = [[BaseScrollView alloc] initWithFrame:CGRectZero];
    [handleScrollView setShowsVerticalScrollIndicator:NO];
    [handleScrollView setBackgroundColor:[UIColor clearColor]];
    [handleScrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [handleScrollView setClipsToBounds:NO];
    handleScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [handleScrollView setDelegate:self];
    [scrollView addSubview:handleScrollView];

    
    self.handle = [[POHandle alloc] initWithController:self];
    [self.handle setDelegate:self];
    // 把手静止时与屏幕边缘保持 5pt 间隙，快捷菜单弹出时沿用该横坐标。
    [handleScrollView addSubview:self.handle];
    
    self.quickSwitchTableView = [[QuickSwitchTableView alloc] init];
    self.quickSwitchTableView.selectionDelegate = self;
    [handleScrollView addSubview:self.quickSwitchTableView];
    
    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.contentView.layer.cornerRadius = CONTENT_CORNER_RADIUS;
    if (@available(iOS 13.0, *)) {
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.contentView.clipsToBounds = YES;
    
    activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    activityIndicator.frame = CGRectMake(42, 54, 37, 37);
    activityIndicator.layer.shadowOpacity = 0.5;
    activityIndicator.layer.shadowRadius = 6;
    activityIndicator.layer.shadowOffset = CGSizeMake(0, 0);
    [activityIndicator startAnimating];

    [self.contentView addSubview:activityIndicator];

    
    // 内容视图需裁剪以遮住托管内容的圆角，也会裁掉自身阴影；单独添加同尺寸圆角阴影视图。
    // 阴影保持紧凑，避免边距较小时显得发灰、松散。
    shadowView = [[UIView alloc] initWithFrame:self.contentView.frame];
    shadowView.backgroundColor = [UIColor clearColor];
    shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowView.layer.shadowOffset = CGSizeMake(0, 1);
    shadowView.layer.shadowRadius = 8;
    // 卡片初始位于右侧屏幕外，进入屏幕前关闭阴影，避免阴影残留在闭合边框。
    shadowView.layer.shadowOpacity = 0;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    [scrollView addSubview:shadowView];

    [scrollView addSubview:self.contentView];
    
    if ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastPinnedBundleId"]) {
        pinnedBundleId = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastPinnedBundleId"];
        UIImage *image = [POApplicationHelper imageForBundleId:pinnedBundleId];
        self.handle.imageView.image = image;
    }else{
        pinnedBundleId = @"com.apple.MobileSMS";
        UIImage *image = [POApplicationHelper imageForBundleId:pinnedBundleId];
        self.handle.imageView.image = image;
    }
    
    [[ContextHostManager sharedInstance] setSceneDelegate:self];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

    [self applyCurrentSettings];
}

-(void)applyCurrentSettings{
    if (!self.isViewLoaded) {
        return;
    }

    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform contentTransform = isLeftHanded
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    dragAndDropImageView.transform = contentTransform;
    dragAndDropLabel.transform = contentTransform;
    self.handle.imageView.transform = contentTransform;
    [self.quickSwitchTableView refreshLayoutDirection];

    if (![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] && origOffset) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
        origOffset = nil;
    }

    [self.handle refreshHandleSizeAnimated:NO];
    [self applyLayoutPreservingHandlePosition:YES];
    [self.handle refreshNubbedPositionAnimated:NO];
    [self resetAutoNubTimer];
}

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];

    if (!CGSizeEqualToSize(lastLaidOutSize, self.view.bounds.size)) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
}

-(void)viewSafeAreaInsetsDidChange{
    [super viewSafeAreaInsetsDidChange];
    // 悬浮 UIWindowScene 的安全区常晚于最终尺寸更新；即使尺寸不变也要重排，
    // 以便首次横屏获得真实的刘海或灵动岛边距，而不是初始的 0。
    [self applyLayoutPreservingHandlePosition:YES];
}

#pragma mark - Geometry

-(CGFloat)trailingSafeAreaInset{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGFloat viewTrailingInset = isLeftHanded ? viewInsets.left : viewInsets.right;
    CGFloat windowTrailingInset = isLeftHanded ? windowInsets.left : windowInsets.right;
    // SpringBoard 可能比根视图早一轮写入场景窗口安全区，取两者较大值可兼容两种时序，
    // 直屏设备仍为 0。
    return MAX(0, MAX(viewTrailingInset, windowTrailingInset));
}

-(CGFloat)maximumContentOffsetX{
    return MAX(0, scrollView.contentSize.width - scrollView.bounds.size.width);
}

-(CGFloat)handleRailWidth{
    // 最大尺寸下仍为把手保留完整轨道和两侧间距，避免外框超出滚动容器后
    // 与卡片或快捷菜单的坐标计算脱节。
    return MAX(HANDLE_MARGIN, CGRectGetWidth(self.handle.bounds) + HANDLE_EDGE_GAP * 2.0);
}

-(CGFloat)maximumHandleOffset{
    return MAX(0, handleScrollView.contentSize.height - handleScrollView.bounds.size.height);
}

-(CGFloat)clampedHandleOffset:(CGFloat)offset{
    return MIN(MAX(0, offset), [self maximumHandleOffset]);
}

-(void)storeHandlePosition{
    handlePoint = handleScrollView.contentOffset;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:NSStringFromCGPoint(handlePoint) forKey:@"handlePoint"];
    CGFloat maximumOffset = [self maximumHandleOffset];
    if (maximumOffset > 0) {
        [defaults setDouble:(handlePoint.y / maximumOffset) forKey:@"handlePointRatio"];
    }
}

-(CGFloat)horizontalOpenProgress{
    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        return 0;
    }
    return MIN(MAX(0, scrollView.contentOffset.x / maximumOffset), 1);
}

// 只有卡片实际回到闭合坐标、且没有拖动/减速/程序化吸附动画时，才允许把手
// 进入快捷切换。isOpened 反映托管状态，不能单独作为视觉闭合状态使用。
-(BOOL)isPanelFullyClosedAndIdle{
    return !self.isOpened &&
        !scrollSnapAnimationInProgress &&
        !scrollView.dragging &&
        !scrollView.decelerating &&
        fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

// 展开态也允许快捷菜单：只要面板不在拖动/吸附过程中即可。
// 闭合态仍要求完全收起，避免半开卡片时误触菜单。
-(BOOL)canPresentQuickSwitchMenu{
    if (scrollSnapAnimationInProgress || scrollView.dragging || scrollView.decelerating) {
        return NO;
    }
    if (self.isOpened) {
        return YES;
    }
    return fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(CGFloat)desiredBackgroundDimAlpha{
    // 快捷菜单结束时不能无脑把遮罩打到 0：展开态应保留打开进度对应的遮罩。
    return [self horizontalOpenProgress];
}

// 点按与拖动释放共用同一条吸附路径。关键：过冲（rubber-band）必须用动画
// 收回到目标，绝不能 setContentOffset:animated:NO 瞬间归位——那就是“闪一下”。
-(void)snapPanelToOpenState:(BOOL)shouldOpen{
    pendingOpenState = shouldOpen;
    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat targetOffset = shouldOpen ? maximumOffset : 0;
    CGFloat rawOffsetX = scrollView.contentOffset.x;
    CGFloat rawOffsetY = scrollView.contentOffset.y;

    BOOL xAlreadyOnTarget = fabs(rawOffsetX - targetOffset) <= CLOSED_CONTENT_OFFSET_EPSILON;
    BOOL yAlreadyClean = fabs(rawOffsetY) <= CLOSED_CONTENT_OFFSET_EPSILON;
    if (xAlreadyOnTarget && yAlreadyClean) {
        scrollSnapAnimationInProgress = NO;
        if (!shouldOpen) {
            self.isOpened = NO;
            [self storeHandlePosition];
            [self resetAutoNubTimer];
        }
        return;
    }

    // 仅 Y 漂移、X 已在目标：无动画修正 Y，不会产生横向闪动。
    if (xAlreadyOnTarget && !yAlreadyClean) {
        [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:NO];
        scrollSnapAnimationInProgress = NO;
        if (!shouldOpen) {
            self.isOpened = NO;
            [self storeHandlePosition];
            [self resetAutoNubTimer];
        }
        return;
    }

    // 中途位置或过冲：从当前位置动画到目标。先冻结在当前帧取消系统惯性，
    // 不要先夹到合法区间（那会跳一帧），再 animated:YES 收回。
    scrollSnapAnimationInProgress = YES;
    if (scrollView.decelerating) {
        [scrollView setContentOffset:scrollView.contentOffset animated:NO];
    }
    [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:YES];
}

-(void)applyLayoutPreservingHandlePosition:(BOOL)preserveHandlePosition{
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 0 || !self.handle) {
        return;
    }

    CGFloat previousMaximumOffset = [self maximumHandleOffset];
    CGFloat handleRatio = previousMaximumOffset > 0
        ? [self clampedHandleOffset:handleScrollView.contentOffset.y] / previousMaximumOffset
        : 0;
    CGFloat previousProgress = scrollView.contentSize.width > scrollView.bounds.size.width
        ? scrollView.contentOffset.x / (scrollView.contentSize.width - scrollView.bounds.size.width)
        : 0;
    BOOL preserveInteractiveOffset =
        scrollView.dragging || scrollView.decelerating || scrollSnapAnimationInProgress;

    CGFloat portraitCanvasWidth = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat portraitCanvasHeight = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat handleRailWidth = [self handleRailWidth];
    chromeScale = (portraitCanvasWidth - handleRailWidth) / portraitCanvasWidth;
    // 横屏上下是手机直边，没有刘海或灵动岛缺口，无需 chromeScale 边距，上下各保留 5pt 即可。
    BOOL isLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    CGFloat contentLayoutHeight;
    if (isLandscape) {
        // 横屏上下是手机侧边框（直线无缺口），卡片高度 = 屏幕高度减去上下各
        // 5pt 间隙即可，无需避开非安全区。托管画布 = 本机真实竖屏尺寸，把
        // 整台竖屏画布等比缩放到该高度，卡片宽度随之得出，App 只重排不变形。
        CGFloat availableCardHeight = CGRectGetHeight(bounds) - (CONTENT_EDGE_GAP * 2);
        CGSize logicalCanvas = [self landscapeLogicalCanvasSizeForBounds:bounds];
        scale = availableCardHeight / logicalCanvas.height;
        // 将卡片对齐到物理像素网格，避免小数缩放在右/下边缘留下
        // 抗锯齿产生的发丝细线。
        CGFloat screenScale = UIScreen.mainScreen.scale;
        contentLayoutWidth = round(logicalCanvas.width * scale * screenScale) / screenScale;
        contentLayoutHeight = round(availableCardHeight * screenScale) / screenScale;
    } else {
        // 竖屏保留 chromeScale 边距以避开非安全区的上下（刘海 / home 条）。
        // 卡片宽度 = 纯内容宽（画布宽 × chromeScale），不在此扣间距——离屏
        // 5pt 间距由下方 trailingInset 单独负责（与横屏一致）。曾在此处减
        // CONTENT_EDGE_GAP 会把间距重复计入、压窄内容，导致设置页右侧滚动条
        // 被裁掉一条。
        CGFloat portraitCardWidth = portraitCanvasWidth * chromeScale;
        CGFloat portraitCardHeight = portraitCanvasHeight * chromeScale;
        CGFloat availableCardHeight = CGRectGetHeight(bounds) * chromeScale;
        CGFloat cardFitScale = MIN(1, availableCardHeight / portraitCardHeight);
        scale = chromeScale * cardFitScale;
        contentLayoutWidth = portraitCardWidth * cardFitScale;
        contentLayoutHeight = portraitCardHeight * cardFitScale;
    }

    self.backgroundView.frame = bounds;
    dragAndDropView.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    dragAndDropLabel.center = CGPointMake(CGRectGetMidX(bounds),
                                          CGRectGetMaxY(dragAndDropView.frame) + 16 + CGRectGetMidY(dragAndDropLabel.bounds));

    scrollView.frame = bounds;
    // 卡片展开后的右边缘位于实体安全区外加 5pt 间隙，闭合时仍在屏幕外；
    // 因此滚动行程为卡片宽度加右侧安全区和间隙，保证把手与卡片始终同步。
    CGFloat trailingInset = [self trailingSafeAreaInset] + CONTENT_EDGE_GAP;
    scrollView.contentSize = CGSizeMake(CGRectGetWidth(bounds) + contentLayoutWidth + trailingInset,
                                        CGRectGetHeight(bounds));
    CGFloat maximumContentOffsetX = [self maximumContentOffsetX];
    CGFloat restoredOffset = 0;
    if (preserveInteractiveOffset) {
        // 拖动/吸附过程中若因安全区变化触发重排，保持连续进度，避免瞬间跳到全开/全关。
        restoredOffset = MIN(MAX(0, previousProgress), 1) * maximumContentOffsetX;
    } else {
        restoredOffset = previousProgress >= 0.5 ? maximumContentOffsetX : 0;
    }
    if (fabs(scrollView.contentOffset.x - restoredOffset) > CLOSED_CONTENT_OFFSET_EPSILON ||
        fabs(scrollView.contentOffset.y) > CLOSED_CONTENT_OFFSET_EPSILON) {
        [scrollView setContentOffset:CGPointMake(restoredOffset, 0) animated:NO];
    }

    CGFloat handleViewportHeight = CGRectGetHeight(bounds) * chromeScale;
    handleScrollView.frame = CGRectMake(CGRectGetWidth(bounds) - handleRailWidth, 0, handleRailWidth, handleViewportHeight);
    handleScrollView.center = CGPointMake(handleScrollView.center.x, CGRectGetMidY(bounds));
    handleScrollView.contentSize = CGSizeMake(handleRailWidth, (handleViewportHeight * 2) - self.handle.frame.size.height);

    CGFloat targetHandleOffset = 0;
    if (preserveHandlePosition) {
        if (previousMaximumOffset <= 0) {
            // 首帧：把手滚动上下文尚未建立（contentSize 还是 0，maxOffset 为 0），
            // 此时 handleRatio 恒为 0，若直接沿用会把把手贴到视口底部。改为读取
            // 用户历史比例，没有则默认停在竖向正中（0.5），而非 offset=0 贴底。
            NSNumber *storedRatio = [[NSUserDefaults standardUserDefaults] objectForKey:@"handlePointRatio"];
            CGFloat ratio = storedRatio ? storedRatio.doubleValue : 0.5;
            targetHandleOffset = ratio * [self maximumHandleOffset];
        } else {
            targetHandleOffset = handleRatio * [self maximumHandleOffset];
        }
    } else {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSNumber *storedRatio = [defaults objectForKey:@"handlePointRatio"];
        NSString *storedPoint = [defaults valueForKey:@"handlePoint"];
        if (storedRatio) {
            targetHandleOffset = storedRatio.doubleValue * [self maximumHandleOffset];
        } else if (storedPoint) {
            targetHandleOffset = CGPointFromString(storedPoint).y;
        } else {
            // 首次安装/重装时没有任何存储位置，默认把手停在竖向正中，
            // 而不是落到 offset=0（贴边）显得跑到边框底下。
            targetHandleOffset = [self maximumHandleOffset] / 2.0;
        }
    }
    [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:targetHandleOffset]) animated:NO];

    self.handle.restingOriginX = handleRailWidth - HANDLE_EDGE_GAP - self.handle.frame.size.width;
    CGRect handleLayoutFrame = self.handle.frame;
    handleLayoutFrame.origin.y = handleViewportHeight - self.handle.frame.size.height;
    if (!self.handle.isNubbed) {
        handleLayoutFrame.origin.x = self.handle.restingOriginX;
    }
    self.handle.frame = handleLayoutFrame;
    [self storeHandlePosition];

    // offset 为 0 时卡片位于实体右边缘外；最大 offset 时其右侧保留安全区加 5pt 间隙，
    // 在 iPad、8 Plus 和刘海设备上均适用。
    self.contentView.frame = CGRectMake(CGRectGetWidth(bounds), 0, contentLayoutWidth, contentLayoutHeight);
    self.contentView.center = CGPointMake(self.contentView.center.x, CGRectGetMidY(bounds));
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGRect alignedCardFrame = self.contentView.frame;
    alignedCardFrame.origin.y = round(alignedCardFrame.origin.y * screenScale) / screenScale;
    self.contentView.frame = alignedCardFrame;
    shadowView.frame = self.contentView.frame;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    CGFloat shadowProgress = MIN(MAX(scrollView.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
    shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;
    activityIndicator.center = CGPointMake(CGRectGetMidX(self.contentView.bounds), CGRectGetMidY(self.contentView.bounds));
    // 加载指示器是 contentView 的直接子视图，只在横屏追加适配缩放，
    // 竖屏维持原尺寸且不会在较矮的横屏卡片中显得过大。
    CGFloat directContentScale = chromeScale > 0 ? scale / chromeScale : 1;
    activityIndicator.transform = CGAffineTransformMakeScale(directContentScale, directContentScale);

    if (contextView) {
        [self layoutContextView];
    }
    if (showingCantHost) {
        [self layoutCantHostView];
    }
    lastLaidOutSize = bounds.size;
    // 全量布局会把 contentView 写回完整展开几何。若快捷菜单仍在展示，
    // 必须基于新的完整 frame 重新计算避让，否则 5pt 间隙会被冲掉。
    if (self.isOpened &&
        self.quickSwitchTableView &&
        self.quickSwitchTableView.alpha > 0.01 &&
        !self.quickSwitchTableView.hidden) {
        quickSwitchYieldActive = NO;
        [self applyQuickSwitchContentYieldIfNeededAnimated:NO];
    }
}

-(void)prepareForOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }

    // 旋转前只清理临时 UI（快捷菜单 / 拖拽预览 / yield）。
    // 新旋转路径会直接 applyInterfaceOrientation + 重布局，必须保留 isOpened、
    // contentOffset 与托管会话，绝不能再强制关闭再手动打开。
    origOffset = nil;
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    [self.quickSwitchTableView dismissImmediately];
    [draggableImageView.layer removeAllAnimations];
    [draggableImageView removeFromSuperview];
    draggableImageView = nil;
    dragAndDropView.transform = CGAffineTransformIdentity;
    dragAndDropView.alpha = 0;
    dragAndDropLabel.alpha = 0;
}

-(void)handleOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }
    // 仅按当前 bounds 重建外壳/把手/卡片几何。
    // 不要在旋转回调里 hostViewForBundleID 重发宿主栈：会与窗口旋转动画抢时序，
    // 反而更容易出现宿主图层方向与外壳短暂错位。
    [self applyLayoutPreservingHandlePosition:YES];
}

-(CGSize)contextManagerPreferredSceneStackSize:(id)manager{
    // 新建的宿主视图需要和布局用同一个逻辑画布，托管内容才能填满卡片而不拉伸。
    // 单一真相源是 landscapeLogicalCanvasSizeForBounds:；竖屏用设备自身尺寸。
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) > CGRectGetHeight(bounds)) {
        return [self landscapeLogicalCanvasSizeForBounds:bounds];
    }
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    return CGSizeMake(shortSide, longSide);
}

// 横屏下托管 App 用于排版的逻辑画布：本机真实的竖屏尺寸（短边×长边）。
// 不伪造任何设备，App 拿到自己真实的尺寸/安全区，据此完整正确布局；
// 整台竖屏画布再等比缩小塞进横屏可用高度。布局和场景栈尺寸都用它。
-(CGSize)landscapeLogicalCanvasSizeForBounds:(CGRect)bounds{
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    return CGSizeMake(shortSide, longSide);
}

-(BOOL)shouldAutorotate
{
    return YES;
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations{
    return UIInterfaceOrientationMaskAll;
}

-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [self applyLayoutPreservingHandlePosition:YES];
    }];
}

-(void)keyboardWillShow:(NSNotification *)notification{
    if (![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue]) {
        return;
    }
    // 托管键盘始终在卡片内，PO 打开时无需避让。只在 PO 关闭、把手常驻边缘时避让真实键盘。
    if (self.isOpened) {
        return;
    }
    CGRect keyboardFrame = [[notification userInfo][UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (!CGRectIntersectsRect(handleInView, keyboardFrameInView)) {
        origOffset = nil;
        return;
    }
    CGFloat overlap = CGRectGetMaxY(handleInView) + HANDLE_EDGE_GAP - CGRectGetMinY(keyboardFrameInView);
    if (overlap > 0) {
        origOffset = @(handleScrollView.contentOffset.y);
        CGFloat adjustedOffset = [self clampedHandleOffset:handleScrollView.contentOffset.y + overlap];
        [handleScrollView setContentOffset:CGPointMake(0, adjustedOffset) animated:YES];
    } else {
        origOffset = nil;
    }
}

-(void)keyboardWillHide:(NSNotification *)notification{
    if ([[POApplicationHelper settings][@"keyboardAvoiding"] boolValue]){
        if (origOffset) {
            [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
            origOffset = nil;
        }
    }
}


-(void)pinAppWithBundleId:(NSString *)bundleId{
    pinnedBundleId = bundleId;
    
    [[NSUserDefaults standardUserDefaults] setObject:bundleId forKey:@"lastPinnedBundleId"];
    UIImage *image = [POApplicationHelper imageForBundleId:bundleId];
    self.handle.imageView.image = image;

    // 切换到不同应用时立即重建宿主。展开态下这就是“就地快速切换”；
    // 闭合态下也会先准备好内容，随后再展开卡片。
    if (![bundleId isEqualToString:hostedBundleId]) {
        hostUpdatesAllowed = YES;
        [self beginHosting];
    }

    if (self.isOpened) {
        // 已展开：保持打开，直接显示新 pin 的内容，无需先关再开。
        [self snapPanelToOpenState:YES];
        return;
    }

    // 选中的应用可能已在前台，此时沿用普通点按的“已打开”处理，不能为了托管而强制回桌面。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self open];
    });
}

-(void)open{
    [self cancelAutoNubTimer];
    // scrollRectToVisible: 会受内容坐标和自动 inset 影响，在 14 Pro Max 上与手动拖动终点不同；
    // 两条路径统一使用同一个展开 offset。
    [self snapPanelToOpenState:YES];
}

-(void)close{
    // 关闭面板前先收起快捷菜单并恢复卡片完整几何，避免 yield 状态残留。
    [self.quickSwitchTableView dismissImmediately];
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    [self snapPanelToOpenState:NO];
}
     

#pragma mark - MHHandleDelegate

-(void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer *)recognizer{
    [self cancelAutoNubTimer];
    if (!self.isOpened) {
        [self open];
    }else{
        [self close];
    }
}

-(void)handle:(POHandle *)handle didLongPress:(UILongPressGestureRecognizer *)recognizer{
    if (![self canPresentQuickSwitchMenu]) {
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self cancelAutoNubTimer];
    }
    if (self.handle.isNubbed) {
        self.handle.isNubbed = NO;
    }

    [self.quickSwitchTableView presentFromHandle:handle withRecognizer:recognizer];

    // 闭合态：菜单出现时加深遮罩；展开态遮罩本就接近 1，结束时恢复到打开进度，
    // 不能直接 alpha=0 把背景遮罩关掉。
    [UIView animateWithDuration:0.3 animations:^{
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            self.backgroundView.alpha = 1.0;
        } else if (recognizer.state != UIGestureRecognizerStateChanged) {
            self.backgroundView.alpha = [self desiredBackgroundDimAlpha];
        }
    }];

    if (recognizer.state != UIGestureRecognizerStateBegan &&
        self.quickSwitchTableView.alpha < 0.01 &&
        !quickSwitchOpeningApp) {
        [self resetAutoNubTimer];
    }
}


#pragma mark - QuickSwitch

-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView didSelectBundleId:(NSString *)bundleId{
    quickSwitchOpeningApp = YES;
    [self cancelAutoNubTimer];
    [self pinAppWithBundleId:bundleId];
}

// 仅更新宿主/占位在卡片内的几何，绝不重设 transform。
// 左手模式 contextView 带 scaleX=-1；若在 UIView 动画块里重新赋值该 transform，
// UIKit 会把 -1 插值成“镜像翻页”假动画。
-(void)syncHostedContentGeometryToContentView{
    if (contextView) {
        CGRect hostBounds = self.contentView.bounds;
        contextView.center = CGPointMake(CGRectGetMidX(hostBounds), CGRectGetMidY(hostBounds));
        for (UIView *v in contextView.subviews) {
            v.frame = contextView.bounds;
            v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    if (showingCantHost && cantHostCanvas) {
        cantHostCanvas.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                            CGRectGetMidY(self.contentView.bounds));
    }
    activityIndicator.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                           CGRectGetMidY(self.contentView.bounds));
}

-(void)applyQuickSwitchContentYieldIfNeeded{
    [self applyQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)applyQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (!self.isOpened || !self.quickSwitchTableView || self.quickSwitchTableView.alpha < 0.01) {
        return;
    }

    // scrollView 本地坐标。左手是 window 级镜像，本地几何与右手一致（把手轨道在本地右侧）。
    CGRect menuInScroll = [self.quickSwitchTableView convertRect:self.quickSwitchTableView.bounds
                                                          toView:scrollView];
    // 基准必须是完整展开卡片：已 yield 时用保存的完整 frame，避免重复叠加位移。
    CGRect baseContentFrame = quickSwitchYieldActive ? quickSwitchSavedContentFrame : self.contentView.frame;
    CGRect baseShadowFrame = quickSwitchYieldActive ? quickSwitchSavedShadowFrame : shadowView.frame;

    // 只平移、不改尺寸：卡片本来就是从把手侧拉出的，菜单出现时往回推最符合手势逻辑，
    // 也避免收窄 frame 造成内容裁切。
    CGRect contentFrame = baseContentFrame;
    CGFloat gap = CONTENT_EDGE_GAP; // 5pt
    CGFloat menuMidX = CGRectGetMidX(menuInScroll);
    CGFloat contentMidX = CGRectGetMidX(contentFrame);
    BOOL menuIsLeftOfContent = menuMidX <= contentMidX;
    CGFloat deltaX = 0;

    if (menuIsLeftOfContent) {
        // 菜单在卡片左侧：整卡右移，使左缘 = 菜单右缘 + 5。
        CGFloat desiredMinX = CGRectGetMaxX(menuInScroll) + gap;
        deltaX = desiredMinX - CGRectGetMinX(contentFrame);
    } else {
        // 菜单在卡片右侧：整卡左移，使右缘 = 菜单左缘 - 5。
        CGFloat desiredMaxX = CGRectGetMinX(menuInScroll) - gap;
        deltaX = desiredMaxX - CGRectGetMaxX(contentFrame);
    }

    if (fabs(deltaX) <= 0.5) {
        if (quickSwitchYieldActive) {
            [self restoreQuickSwitchContentYieldIfNeededAnimated:animated];
        }
        return;
    }

    if (!quickSwitchYieldActive) {
        quickSwitchSavedContentFrame = baseContentFrame;
        quickSwitchSavedShadowFrame = baseShadowFrame;
        quickSwitchYieldActive = YES;
    }

    contentFrame.origin.x += deltaX;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    contentFrame.origin.x = round(contentFrame.origin.x * screenScale) / screenScale;
    // 尺寸保持完整展开尺寸，阴影同移。
    CGRect shadowFrame = baseShadowFrame;
    shadowFrame.origin.x = contentFrame.origin.x;
    shadowFrame.origin.y = contentFrame.origin.y;
    shadowFrame.size = contentFrame.size;

    void (^applyFrames)(void) = ^{
        self.contentView.frame = contentFrame;
        shadowView.frame = shadowFrame;
        shadowView.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
        // 仅平移，宿主尺寸未变，不需要重布局，避免左手 transform 被动画插值。
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        applyFrames();
    }
}

-(void)restoreQuickSwitchContentYieldIfNeeded{
    [self restoreQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)restoreQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (!quickSwitchYieldActive) {
        return;
    }
    quickSwitchYieldActive = NO;
    CGRect contentFrame = quickSwitchSavedContentFrame;
    CGRect shadowFrame = quickSwitchSavedShadowFrame;

    void (^applyFrames)(void) = ^{
        self.contentView.frame = contentFrame;
        shadowView.frame = shadowFrame;
        shadowView.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        applyFrames();
    }
}

-(void)quickSwitchTableViewWillAppear:(QuickSwitchTableView *)quickSwitchTableView{
    // 展开时 contentView 默认盖住把手轨道。菜单弹出时把手轨道提到卡片之上，
    // 且菜单必须在把手之上。
    [scrollView bringSubviewToFront:handleScrollView];
    [handleScrollView insertSubview:self.handle belowSubview:self.quickSwitchTableView];
    [handleScrollView bringSubviewToFront:self.quickSwitchTableView];

    // 展开态：整卡往回推，给菜单留 5pt——像把手把视图再推回去一点。
    [self applyQuickSwitchContentYieldIfNeededAnimated:YES];

    dragAndDropView.alpha = 1;
    if (![[POApplicationHelper settings][@"hideLabels"] boolValue]){
        dragAndDropLabel.alpha = 1;
    }
}

// 保留给菜单布局的可选查询（当前菜单自身不再依赖此避让）。
-(UIView *)quickSwitchContentViewForLayout{
    return self.contentView;
}

-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView draggingDidChangeForQuickSwitchItem:(SBApplication *)app withPoint:(CGPoint)point{
    
    if (!draggableImageView) {
        draggableImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 80, 80)];
        draggableImageView.image = [POApplicationHelper imageForBundleId:app.bundleIdentifier];
        draggableImageView.contentMode = UIViewContentModeScaleAspectFill;
        draggableImageView.center = [self.backgroundView convertPoint:point fromView:quickSwitchTableView];
        [self.backgroundView addSubview:draggableImageView];
        
        if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
            draggableImageView.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(-1.0, 1.0), CGAffineTransformMakeScale(0.01, 0.01));
            [UIView animateWithDuration:0.2 animations:^{
                draggableImageView.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(-1.0, 1.0), CGAffineTransformMakeScale(1, 1));
            }];
        }else{
            draggableImageView.transform = CGAffineTransformMakeScale(0.01, 0.01);
            [UIView animateWithDuration:0.2 animations:^{
                draggableImageView.transform = CGAffineTransformMakeScale(1, 1);
            }];
        }
    }
    
    draggableImageView.center = [self.backgroundView convertPoint:point fromView:quickSwitchTableView];

    CGPoint locationInView = [dragAndDropView convertPoint:point fromView:quickSwitchTableView];
    if (CGRectContainsPoint(dragAndDropView.bounds, locationInView) ) {
        [UIView animateWithDuration:0.3f animations:^{
            NSString *format = POLocalizedString(@"Open %@", @"Tweak");
            dragAndDropLabel.text = [NSString stringWithFormat:format, app.displayName];
            dragAndDropView.transform = CGAffineTransformMakeScale(1.3, 1.3);
        }];
    }else{
        [UIView animateWithDuration:0.3f animations:^{
            dragAndDropLabel.text = POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
            dragAndDropView.transform = CGAffineTransformMakeScale(1, 1);
        }];
    }
}

-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView didDropApp:(SBApplication *)app atPoint:(CGPoint)point{
    quickSwitchOpeningApp = YES;
    [self cancelAutoNubTimer];
    [self removeDraggableImageViewAnimated];
    
    if (CGRectContainsPoint(dragAndDropView.bounds, [dragAndDropView convertPoint:point fromView:quickSwitchTableView]) ) {
        [[UIApplication sharedApplication] launchApplicationWithIdentifier:app.bundleIdentifier suspended:NO];
    }
}

-(void)draggingDidEnterBoundsOfQuickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView{
    [self removeDraggableImageViewAnimated];
}

-(void)removeDraggableImageViewAnimated{
    [draggableImageView.layer removeAllAnimations];

    
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
        draggableImageView.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(-1.0, 1.0), CGAffineTransformMakeScale(1, 1));
        [UIView animateWithDuration:0.2 animations:^{
            draggableImageView.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(-1.0, 1.0), CGAffineTransformMakeScale(0.01, 0.01));
        }completion:^(BOOL finished) {
            [draggableImageView removeFromSuperview];
            draggableImageView = nil;
        }];

    }else{
        draggableImageView.transform = CGAffineTransformMakeScale(1, 1);
        [UIView animateWithDuration:0.2 animations:^{
            draggableImageView.transform = CGAffineTransformMakeScale(0.01, 0.01);
        }completion:^(BOOL finished) {
            [draggableImageView removeFromSuperview];
            draggableImageView = nil;
        }];
    }

    
    [UIView animateWithDuration:0.3f animations:^{
        dragAndDropLabel.text = POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
        dragAndDropView.transform = CGAffineTransformMakeScale(1, 1);
    }];
}

-(void)quickSwitchTableViewDidDisappear:(QuickSwitchTableView *)quickSwitchTableView{
    // 菜单关闭：恢复卡片位置与层级。
    [self restoreQuickSwitchContentYieldIfNeeded];
    [scrollView bringSubviewToFront:shadowView];
    [scrollView bringSubviewToFront:self.contentView];

    dragAndDropView.alpha = 0;
    dragAndDropLabel.alpha = 0;
    self.backgroundView.alpha = [self desiredBackgroundDimAlpha];

    if (quickSwitchOpeningApp) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isOpened) {
                self->quickSwitchOpeningApp = NO;
                [self resetAutoNubTimer];
            }
        });
        return;
    }
    [self resetAutoNubTimer];
}



#pragma mark - UIScrollViewDelegate

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch{
    if (gestureRecognizer != closeTapGestureRecognizer) {
        return YES;
    }

    // 展开时点按把手只允许把手手势关闭卡片，不能同时触发背景点按，
    // 否则两个关闭动画会并发，导致把手跑出可视区域。
    for (UIView *view = touch.view; view; view = view.superview) {
        if (view == self.handle) {
            return NO;
        }
    }
    return YES;
}

-(void)scrollViewWillEndDragging:(UIScrollView *)sv
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset{
    if (sv != scrollView) {
        return;
    }

    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        targetContentOffset->x = 0;
        targetContentOffset->y = 0;
        return;
    }

    // 根据卡片实际行程吸附到展开或闭合状态，不使用整屏分页；快速横向甩动优先，其他情况取最近状态。
    CGFloat projectedOffset = MIN(MAX(0, targetContentOffset->x), maximumOffset);
    BOOL shouldOpen = velocity.x > 0.15 ||
        (velocity.x >= -0.15 && projectedOffset >= maximumOffset / 2.0);
    pendingOpenState = shouldOpen;
    // 释放后由 snapPanelToOpenState: 统一执行动画。把系统投影钉在“当前帧”
    // （含过冲值），而不是夹到合法区间——否则系统会先硬跳一帧再动画。
    targetContentOffset->x = sv.contentOffset.x;
    targetContentOffset->y = 0;
}

-(void)scrollViewWillBeginDragging:(UIScrollView *)sv{
    if (sv == scrollView || sv == handleScrollView) {
        [self cancelAutoNubTimer];
    }
    if (sv == scrollView) {
        // 用户重新触摸会打断已有的程序化滚动，后续由本次拖动结束时重新吸附。
        scrollSnapAnimationInProgress = NO;
    }
}

-(void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decelerate{
    if (sv == handleScrollView) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
        return;
    }
    if (sv != scrollView) {
        return;
    }
    (void)decelerate;
    // 即使 UIScrollView 判断会减速，也不要让其用手势速度自行收尾：
    // snapPanelToOpenState: 会先停止减速，再走固定的点击同款动画。
    [self snapPanelToOpenState:pendingOpenState];
}

-(void)scrollViewDidEndDecelerating:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    if (!pendingOpenState && [self isPanelFullyClosedAndIdle]) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
}

-(void)scrollViewDidEndScrollingAnimation:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    scrollSnapAnimationInProgress = NO;
    if (!pendingOpenState && fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON) {
        // UIKit 的动画回调后将坐标规范为精确的闭合点；此时才结束托管并
        // 放开快捷切换，保证视觉和交互状态同步。
        [scrollView setContentOffset:CGPointZero animated:NO];
        self.isOpened = NO;
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
}

-(void)scrollViewDidScroll:(UIScrollView *)sv{
    if (sv == scrollView) {
        // 允许两端过冲；阴影/进度用归一化值，把手收起仍读原始 offset。
        CGFloat progress = [self horizontalOpenProgress];
        self.backgroundView.alpha = progress;

        // 在前 12pt 行程内渐显卡片阴影。闭合时卡片在屏幕外，8pt 阴影也必须完全透明，
        // 防止边框残影。过冲时 offset 可能 > max，阴影保持满不透明度即可。
        CGFloat shadowProgress = MIN(MAX(sv.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
        shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;

        // 卡片刚露出就启动托管，不要等 progress≈1 才 beginHosting。
        // 否则半拉过程中 stopHosting 后的白底会一直挂到完全展开才刷新。
        // 关闭仍只在真正回零后的吸附收尾里 endHosting，避免半途反复启停。
        if (progress >= 0.02f) {
            if (!self.isOpened) {
                self.isOpened = YES;
            }
        }

        // 手动缩回把手依赖原始横向 offset。上方的归一化进度会限制在 [0, 1]，
        // 会抹去原实现用于判断越过闭合边缘的负向回弹。
        CGFloat rawOffsetX = sv.contentOffset.x;
        if (rawOffsetX < -0.5) {
            if (!self.handle.isNubbed) {
                self.handle.isNubbed = YES;
            }
        } else if (rawOffsetX > 0.5) {
            if (self.handle.isNubbed) {
                self.handle.isNubbed = NO;
            }
        }
    }
}

-(void)setIsOpened:(BOOL)isOpened{
    if (_isOpened == isOpened) {
        return;
    }
    _isOpened = isOpened;
    
    if (isOpened) {
        hostUpdatesAllowed = YES;
        quickSwitchOpeningApp = NO;
        [self cancelAutoNubTimer];
        [self beginHosting];
    }else{
        [self.quickSwitchTableView dismissImmediately];
        [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
        [self endHosting];
        [self resetAutoNubTimer];
    }
}

-(void)cancelAutoNubTimer{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoNubAfterDelay) object:nil];
}

-(void)resetAutoNubTimer{
    [self cancelAutoNubTimer];
    if (![[POApplicationHelper settings][@"autoNub"] boolValue] || self.isOpened || self.handle.isNubbed) {
        return;
    }

    NSTimeInterval delay = MAX(0, [[POApplicationHelper settings][@"autoNub-time"] doubleValue]);
    [self performSelector:@selector(autoNubAfterDelay) withObject:nil afterDelay:delay];
}

-(void)autoNubAfterDelay{
    if ([[POApplicationHelper settings][@"autoNub"] boolValue] && !self.isOpened && !self.handle.isNubbed) {
        [self.handle setIsNubbed:YES];
    }
}


-(void)beginHosting{
    if (!hostUpdatesAllowed || pinnedBundleId.length == 0) {
        return;
    }

    if (![hostingRequestBundleId isEqualToString:pinnedBundleId]) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
        hostingRequestBundleId = [pinnedBundleId copy];
        hostingAttempts = 0;
    }

    if (![[POApplicationHelper frontMostBundleId] isEqualToString:pinnedBundleId]) {
        // 切换到不同应用时，暂存旧应用；新内容上屏后再让旧应用进入后台，避免白屏。
        if (hostedBundleId && ![hostedBundleId isEqualToString:pinnedBundleId]) {
            pendingBackgroundBundleId = hostedBundleId;
        }

        // 每次均从当前图层重新发布场景，包括重新打开同一个应用。这会刷新宿主内容，
        // 避免图层存在但尚未渲染时宿主永久空白；不要预先清除旧快照，否则会露出白屏。
        showingCantHost = NO;
        ContextHostManager *contextManager = [ContextHostManager sharedInstance];
        [contextManager hostViewForBundleID:pinnedBundleId];

        if (contextView && [hostedBundleId isEqualToString:pinnedBundleId] &&
            [contextManager isHostingBundleReady:pinnedBundleId]) {
            // 应用场景已就绪，代理已同步替换为最新内容。
            hostingAttempts = 0;
            [activityIndicator stopAnimating];
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
            return;
        }

        // 新场景尚未生成时保留旧的可见内容，避免冷启动期间露出空白卡片；新图层
        // 由代理确认就绪后才会原子替换旧内容。占位画布没有可保留内容，应立即移除。
        if (!contextView && cantHostCanvas) {
            [self cleanUpSubviews];
        }
        [activityIndicator startAnimating];
        [self.contentView bringSubviewToFront:activityIndicator];
        hostingAttempts += 1;
        // 场景晚于启动请求创建时继续等待；前 6 秒快速重试，之后降为每秒一次。
        // ContextHostManager 不会重复启动同一应用，因此长期等待不会打断冷启动。
        NSTimeInterval retryDelay = hostingAttempts <= HOSTING_FAST_RETRY_LIMIT ? 0.5 : 1.0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
        [self performSelector:@selector(beginHosting) withObject:nil afterDelay:retryDelay];
    }else{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
        hostingRequestBundleId = nil;
        hostingAttempts = 0;
        [activityIndicator stopAnimating];
        if (!showingCantHost) {
            // 固定应用处于前台而无法托管时，让先前展示的应用进入后台、移除实时快照并显示占位内容。
            ContextHostManager *contextManager = [ContextHostManager sharedInstance];
            [contextManager stopHosting];
            if (pendingBackgroundBundleId && ![pendingBackgroundBundleId isEqualToString:pinnedBundleId]) {
                [contextManager backgroundSceneForBundleId:pendingBackgroundBundleId];
            }
            pendingBackgroundBundleId = nil;
            [self cleanUpSubviews];
            [contextView removeFromSuperview];
            contextView = nil;
            hostedBundleId = nil;
            [self showCantHostView];
        }
    }
}

-(void)layoutContextView{
    if (!contextView) {
        return;
    }

    BOOL wasAlreadyAttached = contextView.superview == self.contentView;
    contextView.transform = CGAffineTransformScale(CGAffineTransformIdentity, scale, scale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
        contextView.transform = CGAffineTransformConcat(contextView.transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    
    if (!wasAlreadyAttached) {
        [self.contentView addSubview:contextView];
    }
    
    CGRect frame = contextView.frame;
    frame.origin.x = 0;
    frame.origin.y = 0;
    frame.size.width = self.contentView.frame.size.width;
    frame.size.height = self.contentView.frame.size.height;
    contextView.frame = frame;
    
    for (UIView *v in contextView.subviews) {
        v.frame = contextView.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    if (wasAlreadyAttached) {
        contextView.alpha = 1;
    } else {
        [UIView animateWithDuration:0.3 animations:^{
            contextView.alpha = 1;
        }];
    }

    
}

-(void)cleanUpSubviews{
    for (UIView *v in self.contentView.subviews) {
        if (![v isKindOfClass:[UIActivityIndicatorView class]]) {
            if (v == cantHostCanvas) {
                cantHostCanvas = nil;
                cantHostIconView = nil;
                cantHostLabel = nil;
            }
            [v removeFromSuperview];
        }
    }
    // 键盘栈挂在 contextView 内，随之被移除，指针一并清空避免悬空
    externalSceneStack = nil;
}

-(void)endHosting{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
    hostingRequestBundleId = nil;
    hostingAttempts = 0;
    [activityIndicator stopAnimating];
    showingCantHost = NO;
    // 闭合时禁止宿主替换，避免延迟图层 KVO 销毁或替换保留视图；下次展开时重新允许。
    hostUpdatesAllowed = NO;

    // 关闭面板必须结束当前托管会话：否则被托管 App 会持续处于 PullOver 强制的
    // 前台状态，与用户正在使用的主 App 争夺场景状态，表现为关闭后应用卡死。
    ContextHostManager *contextManager = [ContextHostManager sharedInstance];
    [contextManager stopHosting];
    if (pendingBackgroundBundleId && ![pendingBackgroundBundleId isEqualToString:[POApplicationHelper frontMostBundleId]]) {
        [contextManager backgroundSceneForBundleId:pendingBackgroundBundleId];
    }
    pendingBackgroundBundleId = nil;

    // 关闭时释放键盘/外部图层栈，键盘图层与前台 App 共享，不还回去不回收
    if (externalSceneStack) {
        [externalSceneStack removeFromSuperview];
        externalSceneStack = nil;
    }

    // 此处不能销毁托管视图。保留 contentView 内的场景栈可让下次拖出时直接显示实时内容，
    // 而不是白底和加载指示器；仅在切换到不同应用时由 beginHosting 延迟替换旧场景。
}

-(void)showCantHostView{
    showingCantHost = YES;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showCantHostView];
        });
        return;
    }

    if (!cantHostCanvas) {
        // 应用已打开、无法托管时显示扫描图标占位；它与宿主场景一样位于逻辑竖屏画布，
        // 不使用已缩放的卡片坐标。
        cantHostCanvas = [[UIView alloc] initWithFrame:CGRectZero];
        cantHostCanvas.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:cantHostCanvas];

        UIImageConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:96 weight:UIImageSymbolWeightRegular];
        UIImage *scannerImage = [UIImage systemImageNamed:@"scanner" withConfiguration:config]
            ?: [UIImage systemImageNamed:@"scanner.fill" withConfiguration:config];
        cantHostIconView = [[UIImageView alloc] initWithImage:scannerImage];
        cantHostIconView.contentMode = UIViewContentModeScaleAspectFit;
        cantHostIconView.tintColor = [UIColor labelColor];
        [cantHostIconView sizeToFit];
        [cantHostCanvas addSubview:cantHostIconView];

        cantHostLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        cantHostLabel.numberOfLines = 1;
        cantHostLabel.textAlignment = NSTextAlignmentCenter;
        cantHostLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cantHostLabel.textColor = [UIColor labelColor];
        cantHostLabel.text = POLocalizedString(@"The current app is already open and can't be shown.", @"Tweak");
        [cantHostCanvas addSubview:cantHostLabel];
    }
    [self layoutCantHostView];
}

-(void)layoutCantHostView{
    if (!cantHostCanvas || !cantHostIconView || !cantHostLabel) {
        return;
    }

    // 与 layoutContextView 保持一致：先让竖屏坐标画布填满卡片，再整体等比缩放，
    // 解决横屏下占位图标与文字过大或被横向裁剪的问题。
    cantHostCanvas.transform = CGAffineTransformScale(CGAffineTransformIdentity, scale, scale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
        cantHostCanvas.transform = CGAffineTransformConcat(cantHostCanvas.transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    CGRect canvasFrame = cantHostCanvas.frame;
    canvasFrame.origin = CGPointZero;
    canvasFrame.size = self.contentView.bounds.size;
    cantHostCanvas.frame = canvasFrame;

    CGFloat width = cantHostCanvas.bounds.size.width;
    CGFloat height = cantHostCanvas.bounds.size.height;
    cantHostIconView.center = CGPointMake(width/2.0, height/2.0 - 40);
    cantHostLabel.frame = CGRectMake(0, 0, MAX(0, width-32), 30);
    cantHostLabel.center = CGPointMake(width/2.0, CGRectGetMaxY(cantHostIconView.frame) + 32);
}

#pragma mark - ExternalSceneDelegate

-(void)contextManager:(id)manager scene:(FBScene *)scene sceneStackDidChange:(UIView *)sceneStack{
    if (!hostUpdatesAllowed ||
        ![(ContextHostManager *)manager isHostingScene:scene forBundleId:pinnedBundleId]) {
        return;
    }
    if (!sceneStack) {
        return;
    }

    // 先挂上新栈，再移除旧栈/占位，避免 cleanUpSubviews 先拆光造成一帧白底。
    UIView *previousContextView = contextView;
    UIView *previousCantHostCanvas = cantHostCanvas;
    contextView = sceneStack;
    // 同实例刷新时不要走“新建淡入”，直接保持可见。
    if (previousContextView == sceneStack) {
        [self layoutContextView];
    } else {
        sceneStack.alpha = 1;
        [self layoutContextView];
        if (previousContextView && previousContextView.superview) {
            [previousContextView removeFromSuperview];
        }
        if (previousCantHostCanvas && previousCantHostCanvas.superview) {
            [previousCantHostCanvas removeFromSuperview];
            if (cantHostCanvas == previousCantHostCanvas) {
                cantHostCanvas = nil;
                cantHostIconView = nil;
                cantHostLabel = nil;
            }
        }
    }

    hostedBundleId = pinnedBundleId;
    hostingAttempts = 0;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginHosting) object:nil];
    showingCantHost = NO;
    [activityIndicator stopAnimating];
    [self.contentView bringSubviewToFront:contextView];

    // 新应用内容已上屏，此时再让切换前应用进入后台，切换过程不会露出白屏。
    if (pendingBackgroundBundleId && ![pendingBackgroundBundleId isEqualToString:pinnedBundleId]) {
        [[ContextHostManager sharedInstance] backgroundSceneForBundleId:pendingBackgroundBundleId];
    }
    pendingBackgroundBundleId = nil;
}


-(void)contextManager:(id)manager scene:(FBScene *)scene externalSceneStackDidChange:(UIView *)sceneStack{
    if (!hostUpdatesAllowed ||
        ![(ContextHostManager *)manager isHostingScene:scene forBundleId:pinnedBundleId]) {
        return;
    }
    if (!contextView || !sceneStack) {
        return;
    }

    // 每次按键都会重新发布键盘栈，替换而非累积，避免多个宿主抢占共享键盘图层
    if (externalSceneStack && externalSceneStack != sceneStack) {
        [externalSceneStack removeFromSuperview];
    }
    externalSceneStack = sceneStack;
    [contextView addSubview:sceneStack];
}


@end
