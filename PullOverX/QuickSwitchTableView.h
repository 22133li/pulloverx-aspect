//
//  QuickSwitchTableView.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <UIKit/UIKit.h>

#import "POApplicationHelper.h"
#import "QuickSwitchTableViewCell.h"

@class QuickSwitchTableView;
@protocol QuickSwitchSelectionDelegate <NSObject>

@optional
// 展开态菜单避让卡片时读取 contentView frame。
-(UIView *)quickSwitchContentViewForLayout;

@required
-(void)quickSwitchTableViewWillAppear:(QuickSwitchTableView *)quickSwitchTableView;
-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView didSelectBundleId:(NSString *)bundleId;
-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView draggingDidChangeForQuickSwitchItem:(id)item withPoint:(CGPoint)point;
-(void)quickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView didDropApp:(SBApplication *)app atPoint:(CGPoint)point;
-(void)draggingDidEnterBoundsOfQuickSwitchTableView:(QuickSwitchTableView *)quickSwitchTableView;
-(void)quickSwitchTableViewDidDisappear:(QuickSwitchTableView *)quickSwitchTableView;

@end


@interface QuickSwitchTableView : UITableView <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, weak) id <QuickSwitchSelectionDelegate> selectionDelegate;
-(void)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer;
-(void)dismissImmediately;
-(void)refreshLayoutDirection;

@end
