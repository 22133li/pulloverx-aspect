//
//  QuickSwitchTableViewCell.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "QuickSwitchTableViewCell.h"

@implementation QuickSwitchTableViewCell

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        // Frosted rounded tile that appears behind the icon only while the row is
        // selected, giving the pulled-out item a proper "app tile" look. Uses a
        // Thin material balances translucency and body. Hidden by default.
        UIBlurEffect *tileBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        UIVisualEffectView *tile = [[UIVisualEffectView alloc] initWithEffect:tileBlur];
        tile.frame = CGRectMake(7, -1, 36, 36);
        tile.layer.cornerRadius = 10;
        tile.layer.cornerCurve = kCACornerCurveContinuous;
        tile.clipsToBounds = YES;
        tile.userInteractionEnabled = NO;
        tile.alpha = 0;
        self.tileView = tile;
        [self addSubview:self.tileView];

        self.imgView = [[UIImageView alloc] initWithFrame:CGRectMake(12, 4, 26, 26)];
        self.imgView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:self.imgView];
        
        self.backgroundColor = [UIColor clearColor];

    }
    return self;
}

@end
