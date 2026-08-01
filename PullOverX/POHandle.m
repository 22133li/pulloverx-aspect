//
//  MHHandle.m
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import "POHandle.h"
#import <QuartzCore/QuartzCore.h>
#import "PullOverViewController.h"

#import "POApplicationHelper.h"

#define PO_HANDLE_DEFAULT_SIZE 34.0
#define PO_HANDLE_MINIMUM_SIZE 34.0
#define PO_HANDLE_MAXIMUM_SIZE 50.0
#define PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE 67.0
#define PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE 80.0
#define PO_HANDLE_MINIMUM_TOUCH_SIZE 52.0

@interface POHandle () <UIGestureRecognizerDelegate> {
    UILabel *messageLabel;
    UIVisualEffectView *blurView;
    UILongPressGestureRecognizer *quickSwitchLongPress;
}

@end

@implementation POHandle

-(CGFloat)handleSize{
    id configuredValue = [POApplicationHelper settings][@"handleSize"];
    CGFloat size = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_SIZE;
    if (size <= 0) {
        size = PO_HANDLE_DEFAULT_SIZE;
    }
    return MIN(MAX(size, PO_HANDLE_MINIMUM_SIZE), PO_HANDLE_MAXIMUM_SIZE);
}

-(CGFloat)nubHiddenPercentage{
    id configuredValue = [POApplicationHelper settings][@"nubHiddenPercentage"];
    CGFloat percentage = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    if (percentage < 0) {
        percentage = PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    }
    return MIN(MAX(percentage, 0), PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE);
}

-(CGFloat)fullCornerRadius{
    // 与 60pt 图标生成时的 12pt 圆角比例保持更协调的视觉关系。
    return CGRectGetWidth(self.bounds) * (8.0 / PO_HANDLE_DEFAULT_SIZE);
}

-(CGFloat)nubbedCornerRadius{
    return CGRectGetWidth(self.bounds) * (6.0 / PO_HANDLE_DEFAULT_SIZE);
}

-(CGFloat)nubbedOriginX{
    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        // init 阶段尚未加入 50pt 宽的把手轨道，使用其固定宽度作为回退。
        containerWidth = 50.0;
    }
    // 隐藏比例按整个把手外框计算：隐藏 67% 即仅露出外框宽度的 33%，
    // 不以内部 App 图标尺寸作为分母。
    CGFloat visibleWidth = CGRectGetWidth(self.bounds) * (1.0 - [self nubHiddenPercentage] / 100.0);
    return containerWidth - visibleWidth;
}

-(void)applyNubbedPosition{
    CGRect frame = self.frame;
    frame.origin.x = [self nubbedOriginX];
    self.frame = frame;
}

-(void)applyHandleSize{
    CGFloat size = [self handleSize];
    CGRect frame = self.frame;
    frame.size = CGSizeMake(size, size);
    self.frame = frame;
    self.layer.cornerRadius = [self fullCornerRadius];

    CGFloat iconSize = MAX(0, size - 10.0);
    self.imageView.frame = CGRectMake((CGRectGetWidth(self.bounds) - iconSize) / 2.0,
                                      (CGRectGetHeight(self.bounds) - iconSize) / 2.0,
                                      iconSize,
                                      iconSize);
    blurView.frame = self.bounds;
    blurView.layer.cornerRadius = self.isNubbed ? [self nubbedCornerRadius] : [self fullCornerRadius];
}

-(instancetype)initWithController:(id)hubController{
    if (self = [super initWithFrame:CGRectMake(0, 0, PO_HANDLE_DEFAULT_SIZE, PO_HANDLE_DEFAULT_SIZE)]) {
        // 把手底色保持透明，通透感完全交给 blur；额外白色填充会让毛玻璃发灰发实。
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        self.layer.cornerRadius = 8;
        [self.layer setShadowColor:[UIColor blackColor].CGColor];
        [self.layer setShadowOpacity:0.32];
        [self.layer setShadowRadius:3.5];
        [self.layer setShadowOffset:CGSizeMake(0, 0)];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];

        quickSwitchLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        quickSwitchLongPress.minimumPressDuration = .3f;
        quickSwitchLongPress.delegate = self;
        quickSwitchLongPress.cancelsTouchesInView = NO;
        [self addGestureRecognizer:quickSwitchLongPress];
        [tap requireGestureRecognizerToFail:quickSwitchLongPress];
        
        
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = self.bounds;
        blurView.userInteractionEnabled = NO;
        blurView.layer.cornerRadius = 8;
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        blurView.clipsToBounds = YES;
        [self addSubview:blurView];
        

        self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self.imageView setBackgroundColor:[UIColor clearColor]];
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.clipsToBounds = YES;
        self.imageView.tintColor = [UIColor lightGrayColor];
        [self addSubview:self.imageView];
        [self applyHandleSize];
        
        [self setIsNubbed:[[NSUserDefaults standardUserDefaults] boolForKey:@"isNubbed"]];
    }
    return self;
}

-(void)setIsNubbed:(BOOL)isNubbed{
    _isNubbed = isNubbed;
    
    [[NSUserDefaults standardUserDefaults] setBool:isNubbed forKey:@"isNubbed"];
    
    [UIView animateWithDuration:0.3 animations:^{
        if (isNubbed) {
            [self applyNubbedPosition];
            blurView.layer.cornerRadius = [self nubbedCornerRadius];
        }else{
            CGRect r = self.frame; r.origin.x = self.restingOriginX; self.frame = r;
            blurView.layer.cornerRadius = [self fullCornerRadius];
        }
    }];
}

-(void)refreshHandleSizeAnimated:(BOOL)animated{
    void (^changes)(void) = ^{
        [self applyHandleSize];
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

-(void)refreshNubbedPositionAnimated:(BOOL)animated{
    if (!self.isNubbed) {
        return;
    }

    void (^changes)(void) = ^{
        [self applyNubbedPosition];
        blurView.layer.cornerRadius = [self nubbedCornerRadius];
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

-(void)layoutSubviews{
    [super layoutSubviews];
    blurView.frame = self.bounds;
}

// 把手外框可在 34–50pt 间调整。收起到边缘时可见部分会随隐藏比例改变，
// 因此命中区始终独立于外框尺寸，覆盖屏幕
// 边缘内侧至少 52pt，而不是只在图标四周机械外扩 5pt；这样半露状态仍能轻松
// 点按或长按，常驻状态也比原来的 44pt 更宽容。
-(BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event{
    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        containerWidth = 50.0;
    }
    // POHandle 位于右侧 50pt 轨道。向轨道内侧扩展到窗口边缘再多覆盖 2pt，
    // 可确保系统窗口内的有效横向命中宽度达到 52pt。
    CGFloat desiredHitLeftInContainer = containerWidth - PO_HANDLE_MINIMUM_TOUCH_SIZE;
    CGFloat leadingInset = MAX(5.0, CGRectGetMinX(self.frame) - desiredHitLeftInContainer);
    CGFloat verticalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetHeight(self.bounds)) / 2.0);
    CGRect hitRect = CGRectMake(-leadingInset,
                                -verticalInset,
                                CGRectGetWidth(self.bounds) + leadingInset + 5.0,
                                CGRectGetHeight(self.bounds) + verticalInset * 2.0);
    return CGRectContainsPoint(hitRect, point);
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if ([self.superview isKindOfClass:[UIScrollView class]]) {
        // 把手位于纵向滚动视图内，长按优先可避免开始选择图标时被滚动手势取消。
        [((UIScrollView *)self.superview).panGestureRecognizer requireGestureRecognizerToFail:quickSwitchLongPress];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}


-(void)tap:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didReceiveTap:recognizer];
}

-(void)longPress:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didLongPress:recognizer];
}


@end
