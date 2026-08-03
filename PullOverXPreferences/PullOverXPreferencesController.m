//
//  PullOverXPreferencesController.m
//  PullOverXPreferences
//
//  Created by Will Smillie on 4/9/19.
//  Copyright (c) 2019 ___ORGANIZATIONNAME___. All rights reserved.
//

#import "PullOverXPreferencesController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>
#import <spawn.h>
#import <math.h>
#import "QSFavoritesPickerController.h"
#import "../POLocalization.h"

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone,
    SBSRelaunchActionOptionsRestartRenderServer = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 2
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason
                         options:(SBSRelaunchActionOptions)options
                       targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(void (^)(NSError *error))result;
@end


#define kSetting_Example_Name @"NameOfAnExampleSetting"
#define kSetting_Example_Value @"ValueOfAnExampleSetting"

#define kSetting_TemplateVersion_Name @"TemplateVersionExample"
#define kSetting_TemplateVersion_Value @"1.0"


#define kUrl_FollowOnTwitter @"https://twitter.com/c1d3rdev"
#define kUrl_MakeDonation @"https://paypal.me/willsmillie"

#define kPrefs_KeyName_Key @"key"
#define kPrefs_KeyName_Defaults @"defaults"

static NSString * const kPOSettingsChangedNotification = @"com.mlgm.pulloverx.settings-changed";

#pragma mark - POValueSliderTableCell

// 偏好设置中的两个数值滑动条共用此实现：滑动中按给定步进取整，并把当前值
// 显示在标题中。使用 PSControlTableCell 可复用既有的写入与 Darwin 通知流程。
@interface POValueSliderTableCell : PSControlTableCell {
    NSString *title;
    NSString *unit;
    CGFloat increment;
}
@property (nonatomic, retain) UISlider *control;
@end

@implementation POValueSliderTableCell

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.accessoryView = self.control;
        self.detailTextLabel.hidden = YES;
    }
    return self;
}

- (UISlider *)newControl {
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 165, 31)];
    slider.continuous = YES;
    return slider;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    title = [specifier propertyForKey:@"label"] ?: @"";
    unit = [specifier propertyForKey:@"unit"] ?: @"";
    increment = MAX(0.01, [[specifier propertyForKey:@"increment"] doubleValue]);
    // 必须在 super 读取并写入 slider 值之前设定 min/max，否则 super 在范围仍为
    // 0 时会把已保存的值 clamp 成 0/最小值，切换样式 reload 后表现为“重置”。
    self.control.minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
    self.control.maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateLabel];
}

- (NSNumber *)controlValue {
    return @(self.control.value);
}

- (void)setValue:(NSNumber *)value {
    [super setValue:value];
    self.control.value = value.doubleValue;
    [self updateLabel];
}

- (void)controlChanged:(UISlider *)slider {
    slider.value = round(slider.value / increment) * increment;
    [super controlChanged:slider];
    [self updateLabel];
}

- (void)updateLabel {
    NSString *suffix = unit.length > 0 ? [NSString stringWithFormat:@"%@", unit] : @"";
    self.textLabel.text = [NSString stringWithFormat:@"%@  %.0f%@", title, self.control.value, suffix];
    [self setNeedsLayout];
}

@end

#pragma mark - POHeaderCell

// 顶部大标题卡片（图标、名称和描述），直接定义在此避免新增编译文件。
@interface POHeaderCell : PSTableCell
@end

@implementation POHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.backgroundColor = [UIColor clearColor];
        self.backgroundColor = [UIColor clearColor];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        UIImage *icon = [UIImage imageNamed:@"PullOverXPreferencesIcon" inBundle:bundle compatibleWithTraitCollection:nil];
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:icon];
        iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:iconImageView];

        NSString *titleKey = [specifier propertyForKey:@"headerTitle"] ?: [specifier propertyForKey:@"label"];
        NSString *title = POLocalizedString(titleKey ?: @"", @"PullOverXPreferences");
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        titleLabel.textColor = [UIColor labelColor];
        titleLabel.adjustsFontSizeToFitWidth = YES;
        titleLabel.minimumScaleFactor = 0.82;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:titleLabel];

        NSString *subtitleKey = [specifier propertyForKey:@"headerSubtitle"] ?: [specifier propertyForKey:@"subtitle"];
        NSString *subtitle = POLocalizedString(subtitleKey ?: @"", @"PullOverXPreferences");
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.numberOfLines = 2;
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [iconImageView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [iconImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [iconImageView.widthAnchor constraintEqualToConstant:46],
            [iconImageView.heightAnchor constraintEqualToConstant:46],

            [titleLabel.leadingAnchor constraintEqualToAnchor:iconImageView.trailingAnchor constant:13],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
            [titleLabel.topAnchor constraintEqualToAnchor:iconImageView.topAnchor constant:1],

            [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
            [subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:iconImageView.bottomAnchor constant:-1]
        ]];
    }
    return self;
}

// PSListController 会将 specifier 的标题写入原始标签，需隐藏以免与自定义界面重叠。
- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end

#pragma mark - POSeparatorCell

// A short divider for the QuickSwitch settings block. PreferenceLoader does
// not expose a plist-only separator cell, so keep this as a one-point custom
// cell instead of using another group header (which would add unwanted space).
@interface POSeparatorCell : PSTableCell {
    UIView *_separatorView;
}
@end

@implementation POSeparatorCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _separatorView = [[UIView alloc] init];
        _separatorView.backgroundColor = [UIColor separatorColor];
        _separatorView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_separatorView];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_separatorView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_separatorView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_separatorView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_separatorView.heightAnchor constraintEqualToConstant:0.5]
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end

#pragma mark - POLinkCell

// 可点击的标题和副标题链接行，右侧使用 Safari 图标，直接定义在此避免新增编译文件。
@interface POLinkCell : PSTableCell {
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIImageView *_indicatorImageView;
    NSString *_linkURL;
}
@end

@implementation POLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSString *title = POLocalizedString([specifier propertyForKey:@"label"] ?: @"", @"PullOverXPreferences");
        NSString *subtitle = POLocalizedString([specifier propertyForKey:@"subtitle"] ?: @"", @"PullOverXPreferences");
        _linkURL = [specifier propertyForKey:@"url"];

        self.selectionStyle = UITableViewCellSelectionStyleNone;

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        _indicatorImageView = [[UIImageView alloc] init];
        _indicatorImageView.image = [UIImage systemImageNamed:@"safari"];
        _indicatorImageView.tintColor = [UIColor tertiaryLabelColor];
        _indicatorImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_indicatorImageView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor systemBlueColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.text = subtitle;
        _subtitleLabel.font = [UIFont systemFontOfSize:12];
        _subtitleLabel.textColor = [[UIColor labelColor] colorWithAlphaComponent:0.6];
        _subtitleLabel.hidden = subtitle.length == 0;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_indicatorImageView.widthAnchor constraintEqualToConstant:20],
            [_indicatorImageView.heightAnchor constraintEqualToConstant:20],
            [_indicatorImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_indicatorImageView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
        ]];

        if (subtitle.length > 0) {
            [NSLayoutConstraint activateConstraints:@[
                [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:-9],
                [_subtitleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:10],
                [_subtitleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
            ]];
        } else {
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor].active = YES;
        }

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLink)];
        [self.contentView addGestureRecognizer:tap];
    }
    return self;
}

- (void)openLink {
    if (_linkURL.length > 0) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_linkURL] options:@{} completionHandler:nil];
    }
}

// 隐藏原始标签，避免 specifier 标题残留在自定义标题和副标题后方。
- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end

#pragma mark - POProfileLinkCell

// 带圆形头像的外部链接行，用于开发者和贡献者资料。
@interface POProfileLinkCell : PSTableCell {
    UIImageView *_avatarImageView;
    UILabel *_titleLabel;
    UIImageView *_indicatorImageView;
    NSString *_linkURL;
}
@end

@implementation POProfileLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSString *title = POLocalizedString([specifier propertyForKey:@"label"] ?: @"", @"PullOverXPreferences");
        NSString *iconName = [specifier propertyForKey:@"icon"];
        _linkURL = [specifier propertyForKey:@"url"];

        self.selectionStyle = UITableViewCellSelectionStyleNone;

        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *resourceName = [iconName stringByDeletingPathExtension];
        UIImage *avatar = [UIImage imageNamed:resourceName inBundle:bundle compatibleWithTraitCollection:nil];
        if (!avatar) {
            avatar = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
        }

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        _avatarImageView = [[UIImageView alloc] initWithImage:avatar];
        _avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarImageView.clipsToBounds = YES;
        _avatarImageView.layer.masksToBounds = YES;
        _avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_avatarImageView];

        _indicatorImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"safari"]];
        _indicatorImageView.tintColor = [UIColor tertiaryLabelColor];
        _indicatorImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_indicatorImageView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor systemBlueColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.78;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_avatarImageView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_avatarImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_avatarImageView.widthAnchor constraintEqualToConstant:30],
            [_avatarImageView.heightAnchor constraintEqualToConstant:30],

            [_indicatorImageView.widthAnchor constraintEqualToConstant:20],
            [_indicatorImageView.heightAnchor constraintEqualToConstant:20],
            [_indicatorImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_indicatorImageView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_avatarImageView.trailingAnchor constant:12],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLink)];
        [self.contentView addGestureRecognizer:tap];
    }
    return self;
}

- (void)openLink {
    if (_linkURL.length > 0) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_linkURL] options:@{} completionHandler:nil];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.imageView.hidden = YES;
    _avatarImageView.layer.cornerRadius = CGRectGetHeight(_avatarImageView.bounds) * 0.5;
}

@end

@implementation PullOverXPreferencesController
@synthesize confettiArea;

-(void)viewDidLoad{
    [super viewDidLoad];

    UIBarButtonItem* respringButton = [[UIBarButtonItem alloc] initWithTitle:POLocalizedString(@"Respring", @"PullOverXPreferences") style:UIBarButtonItemStylePlain target:self action:@selector(confirmRespring:)];
    self.navigationItem.rightBarButtonItem = respringButton;
}

-(void)viewWillAppear:(BOOL)view{
    [super viewWillAppear:view];
    
//    [self updateStyle];
}



-(void)viewDidAppear:(BOOL)view{
    [super viewDidAppear:view];
    
    if (!confettiArea) {
        confettiArea = [[L360ConfettiArea alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        confettiArea.userInteractionEnabled = NO;
        confettiArea.delegate = self;
        [self.splitViewController.view addSubview:confettiArea];
    }
    
}

-(void)burst{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:POLocalizedString(@"Please Respring!", @"PullOverXPreferences") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:POLocalizedString(@"Later", @"PullOverXPreferences") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:POLocalizedString(@"Respring", @"PullOverXPreferences") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self respring];
    }]];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    
    [confettiArea burstAt:confettiArea.center confettiWidth:10.0f numberOfConfetti:60];
}

-(IBAction)confirmRespring:(id)sender{
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:POLocalizedString(@"Alert", @"PullOverXPreferences") message:POLocalizedString(@"Are you sure you want to respring?", @"PullOverXPreferences") preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Cancel", @"PullOverXPreferences") style:UIAlertActionStyleCancel handler:nil];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Respring", @"PullOverXPreferences") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [self respring];
    }];
    [alertController addAction:cancelAction];
    [alertController addAction:okAction];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

-(void)respring{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SBSRelaunchActionOptions options = SBSRelaunchActionOptionsRestartRenderServer |
                                           SBSRelaunchActionOptionsFadeToBlackTransition;
        SBSRelaunchAction *action = [NSClassFromString(@"SBSRelaunchAction") actionWithReason:@"PullOverX" options:options targetURL:nil];
        [[NSClassFromString(@"FBSSystemService") sharedService] sendActions:[NSSet setWithObject:action] withResult:nil];
    });
}


- (id)getValueForSpecifier:(PSSpecifier*)specifier
{
	id value = nil;
	
	NSDictionary *specifierProperties = [specifier properties];
	NSString *specifierKey = [specifierProperties objectForKey:kPrefs_KeyName_Key];
	
	// 仅通过代码读取的值。
	if ([specifierKey isEqualToString:kSetting_TemplateVersion_Name])
	{
		value = kSetting_TemplateVersion_Value;
	}
    

		// 存在 defaults 键时，从 cfprefs 域读取值。
	NSString *suiteName = [specifierProperties objectForKey:kPrefs_KeyName_Defaults];
	if (suiteName.length > 0)
	{
		NSUserDefaults *defaults = [self userDefaultsForSuite:suiteName];
        id objectValue = [defaults objectForKey:specifierKey];

        // 缺失该键（含配置被整体删除）时，回落到 specifier 的 default，
        // 使所有设置项都能显示默认值，而不是一片空白。与 Kayoko registerDefaults 等效。
        if (!objectValue) {
            objectValue = [specifierProperties objectForKey:@"default"];
        }

		if (objectValue)
		{
			value = [NSString stringWithFormat:@"%@", objectValue];
		}
    }

	return value;
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier*)specifier
{
	NSDictionary *specifierProperties = [specifier properties];
	NSString *specifierKey = [specifierProperties objectForKey:kPrefs_KeyName_Key];

		NSString *suiteName = [specifierProperties objectForKey:kPrefs_KeyName_Defaults];
		if (suiteName.length > 0){
			NSUserDefaults *defaults = [self userDefaultsForSuite:suiteName];
			if (value) {
				[defaults setObject:value forKey:specifierKey];
			} else {
				[defaults removeObjectForKey:specifierKey];
			}
			[defaults synchronize];
			CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
														(__bridge CFStringRef)kPOSettingsChangedNotification,
														NULL,
														NULL,
														true);
		}

	if ([specifierKey isEqualToString:@"style"]){
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_specifiers = nil;
            [self reloadSpecifiers];
        });
    }
}

// 用 cfprefsd 域（与 tweak 同一 suite）。specifier plist 的 defaults 键给出纯标识符
// "com.mlgm.pulloverx"，直接作 suiteName，由系统定位物理位置，三方案通用不写死路径。
- (NSUserDefaults *)userDefaultsForSuite:(NSString *)suiteName
{
	NSString *resolved = suiteName;
	// 兼容历史写法：若误带完整路径/后缀，取文件名主干作纯标识符。
	if ([resolved hasPrefix:@"/"]) {
		resolved = [[resolved lastPathComponent] stringByDeletingPathExtension];
	}
	return [[NSUserDefaults alloc] initWithSuiteName:resolved];
}

- (void)followOnTwitter:(PSSpecifier*)specifier
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:kUrl_FollowOnTwitter] options:@{} completionHandler:nil];
}

- (void)followAskusio_rrOnTwitter:(PSSpecifier*)specifier
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://twitter.com/akusio_RR"] options:@{} completionHandler:nil];
}


- (void)makeDonation:(PSSpecifier *)specifier
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:kUrl_MakeDonation] options:@{} completionHandler:nil];
}

- (id)specifiers
{
	if (_specifiers == nil) {
		_specifiers = [self loadSpecifiersFromPlistName:@"PullOverXPreferences" target:self];
		self.title = POLocalizedString(@"PullOver X", @"PullOverXPreferences");

		// PreferenceLoader 的 plist 保持语言无关，加载后再翻译以保留原有键和值。
		for (PSSpecifier *specifier in _specifiers) {
			NSString *label = [specifier propertyForKey:@"label"];
			if (label.length > 0) {
				[specifier setProperty:POLocalizedString(label, @"PullOverXPreferences") forKey:@"label"];
			}
			NSString *footer = [specifier propertyForKey:@"footerText"];
			if (footer.length > 0) {
				[specifier setProperty:POLocalizedString(footer, @"PullOverXPreferences") forKey:@"footerText"];
			}
		}

        BOOL showRecentApps = ![[POApplicationHelper settings][@"style"] isEqualToString:@"Favorite Apps"];
        NSMutableArray *filteredSpecifiers = [NSMutableArray arrayWithCapacity:_specifiers.count];
        for (PSSpecifier *specifier in _specifiers) {
            NSString *identifier = [specifier propertyForKey:@"id"];
            if (showRecentApps && [identifier isEqualToString:@"favoriteApps"]) {
                continue;
            }
            if (!showRecentApps && ([identifier isEqualToString:@"recentAppsCount"] ||
                                    [identifier isEqualToString:@"quickSwitchRecentAppsDivider"])) {
                continue;
            }
            [filteredSpecifiers addObject:specifier];
        }
        _specifiers = filteredSpecifiers;
	}
    
    return _specifiers;
}

- (id)init
{
	if ((self = [super init]))
	{
	}
	
	return self;
}


-(NSArray *)stylesDataSource{
    return @[@"Recent Apps", @"Favorite Apps"];
}

-(NSArray *)styleTitlesDataSource{
    return @[POLocalizedString(@"Recent Apps", @"PullOverXPreferences"), POLocalizedString(@"Favorite Apps", @"PullOverXPreferences")];
}

-(void)selectFavorites:(PSSpecifier *)specifier{
    QSFavoritesPickerController *c = [[QSFavoritesPickerController alloc] init];
    [self.navigationController pushViewController:c animated:YES];
}

@end
