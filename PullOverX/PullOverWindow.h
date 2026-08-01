//
//  PullOverWindow.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "PullOverViewController.h"

@interface PullOverWindow : UIWindow

@property (nonatomic, strong) PullOverViewController *controller;

+ (id)sharedWindow;
// 请求 UIKit 按当前场景重新布局悬浮窗口，不能手动修改场景管理的窗口尺寸。
- (void)requestLayoutFromCurrentScene;
// 将 PullOver 这个窗口单独旋转到 FrontBoard 报告的真实方向，不修改 SpringBoard 场景方向。
- (BOOL)applyInterfaceOrientation:(UIInterfaceOrientation)orientation
                         duration:(NSTimeInterval)duration
                            force:(BOOL)force;

@end
