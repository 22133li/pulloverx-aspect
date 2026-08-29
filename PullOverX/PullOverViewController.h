//
//  PullOverViewController.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#import "BaseScrollView.h"
#import "POHandle.h"
#import "QuickSwitchTableView.h"
#import "ContextHostManager.h"

#import "IPC.h"
#import "headers.h"


@interface PullOverViewController : UIViewController <UIScrollViewDelegate, POHandleDelegate, QuickSwitchSelectionDelegate>

-(void)close;
-(void)endHosting;
-(void)applyCurrentSettings;
// FrontBoard 真实方向更新或 SpringBoard 兼容回调触发窗口旋转前后调用。
-(void)prepareForOrientationChange;
-(void)handleOrientationChange;
// 1.96: URL scheme 入口 - pulloverx://pin?bundleId=X&url=Y&banner=Z
-(void)handleIncomingURL:(NSURL *)url;
// 1.96: 黑名单/域名排除查询
-(BOOL)isURLExcluded:(NSString *)urlString;
@property (nonatomic) BOOL isOpened;

@property (nonatomic) CGFloat currentDynamicRatio; // 1.93: 动态比例模式下的当前 ratio (用户拖拽决定)
@property (nonatomic, strong) UIPanGestureRecognizer *resizePanGesture; // 1.93: 拖拽改变窗口高度的手势

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIScrollView *handleScrollView;
@property (nonatomic, strong) UIView *backgroundView;

@property (nonatomic, strong) POHandle *handle;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) QuickSwitchTableView *quickSwitchTableView;


@end
