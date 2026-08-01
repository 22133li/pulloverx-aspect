//
//  MHHandle.h
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import <UIKit/UIKit.h>

@class POHandle;
@protocol POHandleDelegate <NSObject>
- (void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer*)recognizer;
- (void)handle:(POHandle *)handle didLongPress:(UIGestureRecognizer*)recognizer;
@end


@interface POHandle : UIView

@property (nonatomic, weak) id <POHandleDelegate> delegate;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic) BOOL isNubbed;
@property (nonatomic) CGFloat restingOriginX;

-(instancetype)initWithController:(id)controller;
// 设置变更时，按新的整个把手尺寸与收起比例刷新外框和位置。
-(void)refreshHandleSizeAnimated:(BOOL)animated;
-(void)refreshNubbedPositionAnimated:(BOOL)animated;


@end
