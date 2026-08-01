//
//  QuickSwitchTableView.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "QuickSwitchTableView.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

#import "PullOverWindow.h"

// 快捷菜单使用独立宽度，不受方形把手尺寸影响。
#define QS_LIST_WIDTH 50
#define QS_ROW_HEIGHT 34.0
#define QS_VERTICAL_SCREEN_EDGE_MARGIN 10.0
// 与把手静止时距屏幕边缘的 5pt 间隙一致，菜单覆盖把手时不会越出屏幕。
#define QS_HORIZONTAL_SCREEN_EDGE_MARGIN 5.0
// 固定圆角让菜单始终保持圆角矩形，不会随高度增加变成药丸形；连续圆角与系统界面一致。
#define QS_CORNER_RADIUS 16.0

@interface QuickSwitchTableView (){
    NSDictionary *settings;
    NSMutableArray *items;
    
    NSIndexPath *lastHoveredIndexPath;
    UITableViewCell *lastCellToAnimate;
    UITableViewCell *thisCellToAnimate;
    SBApplication *draggingApp;
    BOOL isPresenting;
    CGFloat presentingHandleHeight;

    // 轻触反馈用于弹出和确认，选择反馈用于滑过图标，比旧版系统震动更轻。
    UIImpactFeedbackGenerator *impactGenerator;
    UISelectionFeedbackGenerator *selectionGenerator;
}

@end

@implementation QuickSwitchTableView

-(instancetype)init{
    if (self = [super init]) {
        [self registerClass:[QuickSwitchTableViewCell class] forCellReuseIdentifier:@"QuickSwitchCell"];
        self.alpha = 0;
        self.clipsToBounds = NO;
        // 显示前已限制图标数量，菜单不允许滚动到背景范围以外的行。
        self.scrollEnabled = NO;
        self.bounces = NO;
        self.alwaysBounceVertical = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        [self.layer setShadowColor:[UIColor blackColor].CGColor];
        [self.layer setShadowOpacity:0.30];
        [self.layer setShadowRadius:3.5];
        [self.layer setShadowOffset:CGSizeMake(0, 0)];
        self.separatorColor = [UIColor clearColor];

        self.delegate = self;
        self.dataSource = self;

        // 表格本身不裁剪，悬停图标可越界放大；由单独裁剪的毛玻璃背景绘制连续圆角。
        // Thin 介于 Material 与 UltraThin 之间：有通透感，又不会空到像没底。
        UIBlurEffect *menuBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        UIVisualEffectView *menuBackground = [[UIVisualEffectView alloc] initWithEffect:menuBlur];
        menuBackground.layer.masksToBounds = YES;
        menuBackground.layer.cornerRadius = QS_CORNER_RADIUS;
        menuBackground.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundView = menuBackground;
        self.backgroundColor = [UIColor clearColor];

        impactGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        selectionGenerator = [[UISelectionFeedbackGenerator alloc] init];
        presentingHandleHeight = 34.0;

        [self refresh];
    }
    return self;
}

-(void)refresh{
    settings = [POApplicationHelper settings];
    items = [NSMutableArray array];

    if ([settings[@"style"] isEqualToString:@"Recent Apps"]){
        if ([settings[@"recentAppsCount"] intValue] > 0) {
            items = [[POApplicationHelper recentAppsWithCount:[settings[@"recentAppsCount"] intValue]] mutableCopy];
        }
    }else{
        if ([settings[@"favorites"] count] > 0) {
            items = [settings[@"favorites"] mutableCopy];
        }
    }
    
    [self reloadData];
}

// 窗口在左手模式下整体水平镜像；图标需镜像一次抵消它，保证 App 图标文字始终正向。
// 该状态可在设置中即时切换，不能只在单元格初始化时决定。
-(CGAffineTransform)appIconLayoutTransform{
    return [[POApplicationHelper settings][@"leftHanded"] boolValue]
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
}

-(void)refreshLayoutDirection{
    CGAffineTransform iconTransform = [self appIconLayoutTransform];
    for (UITableViewCell *cell in self.visibleCells) {
        if ([cell isKindOfClass:[QuickSwitchTableViewCell class]]) {
            ((QuickSwitchTableViewCell *)cell).imgView.transform = iconTransform;
        }
    }
}


-(void)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self refresh];
        presentingHandleHeight = MAX(0, CGRectGetHeight(handle.bounds));
        if ([settings[@"hapticFeedback"] boolValue]) {
            [impactGenerator prepare];
            [impactGenerator impactOccurred];
            [selectionGenerator prepare];
        }
        if (items.count == 0) {
            isPresenting = NO;
            return;
        }

        lastHoveredIndexPath = nil;
        draggingApp = nil;

        UIScrollView *hostScrollView = (UIScrollView *)self.superview;
        UIView *coordinateView = self.window ?: hostScrollView.superview;
        CGFloat verticalMargin = QS_VERTICAL_SCREEN_EDGE_MARGIN;
        CGFloat availableHeight = MAX(0, CGRectGetHeight(coordinateView.bounds) - verticalMargin * 2);

        // 保留靠近顶部的项目并从底部裁去超出部分，横竖屏下每个图标都完整位于菜单内。
        NSUInteger maximumVisibleItems = (NSUInteger)floor(availableHeight / QS_ROW_HEIGHT);
        if (maximumVisibleItems == 0) {
            isPresenting = NO;
            return;
        }
        if (items.count > maximumVisibleItems) {
            [items removeObjectsInRange:NSMakeRange(maximumVisibleItems, items.count - maximumVisibleItems)];
            [self reloadData];
        }
        [self setContentOffset:CGPointZero animated:NO];
        CGFloat height = QS_ROW_HEIGHT * items.count;

        // 菜单始终对齐把手；屏幕边距内夹紧。展开态的 5pt 间隙由 contentView 避让菜单实现，
        // 绝不能把菜单挤出屏幕。
        CGFloat listX = handle.frame.origin.x + handle.frame.size.width - QS_LIST_WIDTH;
        CGFloat handleCenterY = handle.frame.origin.y + handle.frame.size.height/2.0;
        CGFloat listY = handleCenterY - height/2.0;
        CGRect menuFrame = CGRectMake(listX, listY, QS_LIST_WIDTH, height);
        CGRect menuFrameInCoordinateView = [self.superview convertRect:menuFrame toView:coordinateView];
        CGRect allowedFrame = UIEdgeInsetsInsetRect(coordinateView.bounds,
                                                    UIEdgeInsetsMake(verticalMargin,
                                                                     QS_HORIZONTAL_SCREEN_EDGE_MARGIN,
                                                                     verticalMargin,
                                                                     QS_HORIZONTAL_SCREEN_EDGE_MARGIN));
        CGFloat horizontalAdjustment = 0;
        CGFloat verticalAdjustment = 0;
        if (CGRectGetMinX(menuFrameInCoordinateView) < CGRectGetMinX(allowedFrame)) {
            horizontalAdjustment = CGRectGetMinX(allowedFrame) - CGRectGetMinX(menuFrameInCoordinateView);
        } else if (CGRectGetMaxX(menuFrameInCoordinateView) > CGRectGetMaxX(allowedFrame)) {
            horizontalAdjustment = CGRectGetMaxX(allowedFrame) - CGRectGetMaxX(menuFrameInCoordinateView);
        }
        if (CGRectGetMinY(menuFrameInCoordinateView) < CGRectGetMinY(allowedFrame)) {
            verticalAdjustment = CGRectGetMinY(allowedFrame) - CGRectGetMinY(menuFrameInCoordinateView);
        } else if (CGRectGetMaxY(menuFrameInCoordinateView) > CGRectGetMaxY(allowedFrame)) {
            verticalAdjustment = CGRectGetMaxY(allowedFrame) - CGRectGetMaxY(menuFrameInCoordinateView);
        }
        if (horizontalAdjustment != 0 || verticalAdjustment != 0) {
            CGPoint adjustedOrigin = CGPointMake(CGRectGetMinX(menuFrameInCoordinateView) + horizontalAdjustment,
                                                 CGRectGetMinY(menuFrameInCoordinateView) + verticalAdjustment);
            menuFrame.origin = [coordinateView convertPoint:adjustedOrigin toView:self.superview];
        }
        self.frame = menuFrame;

        // 使用固定连续圆角保持圆角矩形；表格不裁剪，因此阴影路径需要显式更新。
        self.layer.cornerRadius = QS_CORNER_RADIUS;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundView.layer.cornerRadius = QS_CORNER_RADIUS;
        self.backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:QS_CORNER_RADIUS].CGPath;
        isPresenting = YES;
        [self present];
        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
        return;
    }

    if (!isPresenting) {
        return;
    }

    CGPoint p = [recognizer locationInView:self];
    NSIndexPath *indexPath = [self indexPathForRowAtPoint:p];
    if (recognizer.state == UIGestureRecognizerStateChanged){
        if (p.x >= 0 && indexPath && (![indexPath isEqual:lastHoveredIndexPath] || draggingApp)){
            [self.selectionDelegate draggingDidEnterBoundsOfQuickSwitchTableView:self];
            if ([settings[@"hapticFeedback"] boolValue]) {
                [selectionGenerator selectionChanged]; // gentle per-row peek
                [selectionGenerator prepare];
            }

            lastCellToAnimate = [self cellForRowAtIndexPath:lastHoveredIndexPath];
            thisCellToAnimate = [self cellForRowAtIndexPath:indexPath];
            [self animateZoomforCellremove:lastCellToAnimate];
            [self animateZoomforCell:thisCellToAnimate];
            
            lastHoveredIndexPath = indexPath;
            draggingApp = nil;
        }else if(p.x < 0 && lastHoveredIndexPath && lastHoveredIndexPath.row < items.count){
            
            [self animateZoomforCellremove:thisCellToAnimate];
            [self animateZoomforCellremove:lastCellToAnimate];
            
            draggingApp = [[objc_getClass("SBApplicationController") sharedInstance] applicationWithBundleIdentifier:items[lastHoveredIndexPath.row]];
            [self.selectionDelegate quickSwitchTableView:self draggingDidChangeForQuickSwitchItem:draggingApp withPoint:p];
        }
    }else if (recognizer.state == UIGestureRecognizerStateEnded){
        if (lastHoveredIndexPath && lastHoveredIndexPath.row < items.count && p.x >= 0) {
            if ([settings[@"hapticFeedback"] boolValue]) {
                [impactGenerator impactOccurred]; // confirm selection
            }
            [self.selectionDelegate quickSwitchTableView:self didSelectBundleId:items[lastHoveredIndexPath.row]];
        }else if (draggingApp) {
            [self.selectionDelegate quickSwitchTableView:self didDropApp:draggingApp atPoint:p];
        }
        
        [self end];
    }else{
        [self end];
    }
}


#pragma mark — TableView

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return items.count;
}

-(CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath{
    return QS_ROW_HEIGHT;
}

- (nonnull UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"QuickSwitchCell";
    QuickSwitchTableViewCell *cell = [self dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[QuickSwitchTableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    
    [cell.imgView setImage:[POApplicationHelper imageForBundleId:items[indexPath.row]]];
    cell.imgView.transform = [self appIconLayoutTransform];

    return cell;
}




#pragma mark - Animations

-(void)present{
    // 以压缩形态从把手展开，使用低阻尼弹簧形成轻微回弹。
    CGFloat fullHeight = self.bounds.size.height;
    CGFloat handleHeight = MIN(presentingHandleHeight, fullHeight);
    CGFloat startScaleY = (fullHeight > handleHeight) ? (handleHeight / fullHeight) : 1.0;

    // 初始状态纵向压缩、横向略微膨胀。
    self.transform = CGAffineTransformMakeScale(1.12, startScaleY);
    self.alpha = 0;

    [UIView animateWithDuration:0.12 animations:^{
        self.alpha = 1;
    }];

    // 低阻尼与较高初速度带来回弹后稳定的效果。
    [UIView animateWithDuration:0.62
                          delay:0
         usingSpringWithDamping:0.58
          initialSpringVelocity:0.9
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

-(void)end{
    [self animateZoomforCellremove:thisCellToAnimate];
    isPresenting = NO;
    draggingApp = nil;
    lastCellToAnimate = nil;
    thisCellToAnimate = nil;
    [UIView animateWithDuration:0.3 animations:^{
        self.alpha = 0;
        lastHoveredIndexPath = nil;
    } completion:^(BOOL finished) {
        [self.selectionDelegate quickSwitchTableViewDidDisappear:self];
    }];
}

-(void)dismissImmediately{
    if (!isPresenting) {
        return;
    }

    [self.layer removeAllAnimations];
    [self animateZoomforCellremove:thisCellToAnimate];
    [self animateZoomforCellremove:lastCellToAnimate];
    self.alpha = 0;
    self.transform = CGAffineTransformIdentity;
    isPresenting = NO;
    draggingApp = nil;
    lastHoveredIndexPath = nil;
    lastCellToAnimate = nil;
    thisCellToAnimate = nil;
    [self.selectionDelegate quickSwitchTableViewDidDisappear:self];
}

-(void)animateZoomforCell:(UITableViewCell*)zoomCell {
    zoomCell.layer.zPosition = 3;

    // 高亮图标从菜单中滑出，避免被手指遮挡；尺寸固定，只做水平位移。
    // 方向规则：优先滑向“离开卡片”的一侧。
    // - 闭合态菜单在屏右：向左滑（屏幕内侧）
    // - 展开态菜单在卡片左侧：仍向左滑（离开卡片，不是滑进卡片）
    // - 仅当左侧确实不够、且右侧更空时才反向。
    CGFloat tileSize = 36.0;
    CGFloat desiredOffset = QS_LIST_WIDTH/2.0 + tileSize/2.0 + 5.0;
    UIView *coordinateView = self.window ?: self.superview.superview ?: self.superview;
    CGRect cellInCoordinate = [zoomCell convertRect:zoomCell.bounds toView:coordinateView];
    CGFloat midX = CGRectGetMidX(cellInCoordinate);
    CGFloat minCenterX = CGRectGetMinX(coordinateView.bounds) + tileSize/2.0 + 1.0;
    CGFloat maxCenterX = CGRectGetMaxX(coordinateView.bounds) - tileSize/2.0 - 1.0;
    CGFloat availableLeft = MAX(0, midX - minCenterX);
    CGFloat availableRight = MAX(0, maxCenterX - midX);

    // 默认向左（历史行为，也符合“离开右侧卡片/离开右手手指”）。
    CGFloat translationX = -MIN(desiredOffset, availableLeft);
    if (availableLeft < desiredOffset * 0.55 && availableRight > availableLeft) {
        // 左侧明显不够时才反向，并吃满右侧可用距离。
        translationX = MIN(desiredOffset, availableRight);
    }
    CGAffineTransform t = (fabs(translationX) > 0.5)
        ? CGAffineTransformMakeTranslation(translationX, 0)
        : CGAffineTransformIdentity;

    QuickSwitchTableViewCell *cell = (QuickSwitchTableViewCell *)zoomCell;
    // 使用平滑缓出动画，避免在行间滑动时产生抖动或掉帧感。
    [UIView animateWithDuration:0.18
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        zoomCell.transform = t;
        if ([cell isKindOfClass:[QuickSwitchTableViewCell class]]) {
            cell.tileView.alpha = 1;
        }
    } completion:nil];
}

-(void)animateZoomforCellremove:(UITableViewCell*)zoomCell {
    zoomCell.layer.zPosition = 2;

    QuickSwitchTableViewCell *cell = (QuickSwitchTableViewCell *)zoomCell;
    [UIView animateWithDuration:0.18
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        zoomCell.transform = CGAffineTransformIdentity;
        if ([cell isKindOfClass:[QuickSwitchTableViewCell class]]) {
            cell.tileView.alpha = 0;
        }
    } completion:nil];
}


@end
