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
@property (nonatomic) BOOL isOpened;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIScrollView *handleScrollView;
@property (nonatomic, strong) UIView *backgroundView;

@property (nonatomic, strong) POHandle *handle;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) QuickSwitchTableView *quickSwitchTableView;


@end
