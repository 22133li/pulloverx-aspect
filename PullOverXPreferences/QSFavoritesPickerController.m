//
//  QSFavoritesPickerController.m
//  PullOverXPreferences
//
//  Created by Will Smillie on 11/12/18.
//

#import "QSFavoritesPickerController.h"
#import "../POLocalization.h"

// 常规（非搜索）模式下的分区结构。
typedef NS_ENUM(NSInteger, QSSection) {
    QSSectionSelected = 0,
    QSSectionUser     = 1,
    QSSectionSystem   = 2,
    QSSectionCount    = 3
};

@interface LSApplicationRecord : NSObject
@property (nonatomic, readonly) NSArray *appTags; // 'hidden'
@property (getter=isLaunchProhibited, readonly) BOOL launchProhibited;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSArray *appTags;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (getter=isLaunchProhibited, nonatomic, readonly) BOOL launchProhibited;
- (LSApplicationRecord *)correspondingApplicationRecord;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

@interface UIImage (POPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

// " hidden "（含空格）同样有效，因此采用子串匹配而非完全相等，与 AltList 行为一致。
static BOOL POTagArrayContainsHidden(NSArray *tags) {
    if (![tags isKindOfClass:[NSArray class]]) {
        return NO;
    }
    for (id tag in tags) {
        if ([tag isKindOfClass:[NSString class]] &&
            [(NSString *)tag rangeOfString:@"hidden" options:0].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// 判断应用是否从主屏幕隐藏，复刻 AltList 的判断；iOS 14 起 proxy.appTags 为空，
// 实际标签位于 correspondingApplicationRecord。
static BOOL POApplicationProxyIsHidden(LSApplicationProxy *proxy) {
    NSArray *appTags = nil;
    NSArray *recordAppTags = nil;
    NSArray *sbAppTags = nil;
    BOOL launchProhibited = NO;

    if ([proxy respondsToSelector:@selector(correspondingApplicationRecord)]) {
        LSApplicationRecord *record = [proxy correspondingApplicationRecord];
        recordAppTags = record.appTags;
        launchProhibited = record.launchProhibited;
    }
    if ([proxy respondsToSelector:@selector(appTags)]) {
        appTags = proxy.appTags;
    }
    if (!launchProhibited && [proxy respondsToSelector:@selector(isLaunchProhibited)]) {
        launchProhibited = proxy.launchProhibited;
    }

    NSURL *bundleURL = proxy.bundleURL;
    if (bundleURL && [bundleURL checkResourceIsReachableAndReturnError:nil]) {
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        sbAppTags = [bundle objectForInfoDictionaryKey:@"SBAppTags"];
    }

    BOOL isWebApplication =
        ([proxy.applicationIdentifier rangeOfString:@"com.apple.webapp" options:NSCaseInsensitiveSearch].location != NSNotFound);

    return POTagArrayContainsHidden(appTags)
        || POTagArrayContainsHidden(recordAppTags)
        || POTagArrayContainsHidden(sbAppTags)
        || isWebApplication
        || launchProhibited;
}

@interface QSFavoritesPickerController () <UISearchResultsUpdating, UISearchControllerDelegate> {
    NSMutableDictionary *settings;

    NSMutableDictionary<NSString *, NSString *> *appNamesByIdentifier;
    NSMutableDictionary<NSString *, NSNumber *> *appTypeByIdentifier; // QSSectionUser / QSSectionSystem

    NSMutableArray<NSString *> *enabledApps;  // ordered favorites
    NSMutableArray<NSString *> *userApps;      // unselected user apps
    NSMutableArray<NSString *> *systemApps;    // unselected system apps

    UISearchController *searchController;
    NSMutableArray<NSString *> *searchResults;
    BOOL isSearching;
}

@end

@implementation QSFavoritesPickerController
@synthesize allApps;

-(instancetype)init{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}
-(instancetype)initWithStyle:(UITableViewStyle)style{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}
-(instancetype)initWithCoder:(NSCoder *)aDecoder{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

-(void)viewDidLoad{
    [super viewDidLoad];

    self.title = POLocalizedString(@"QuickSwitch Favorites", @"PullOverXPreferences");

    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.allowsSelectionDuringEditing = YES;
    // 常规模式始终处于编辑状态，使“已选择”分区的排序拖拽把手一直可见。
    [self.tableView setEditing:YES animated:NO];

    appNamesByIdentifier = [NSMutableDictionary dictionary];
    appTypeByIdentifier = [NSMutableDictionary dictionary];
    enabledApps = [NSMutableArray array];
    userApps = [NSMutableArray array];
    systemApps = [NSMutableArray array];
    searchResults = [NSMutableArray array];
    allApps = [NSMutableArray array];

    [self loadInstalledApps];
    [self loadSavedFavorites];

    [self setupSearchController];
}

#pragma mark - Data loading

-(void)loadInstalledApps{
    NSMutableArray<NSString *> *loadedUser = [NSMutableArray array];
    NSMutableArray<NSString *> *loadedSystem = [NSMutableArray array];

    NSArray *installedApps = [[LSApplicationWorkspace defaultWorkspace] allApplications];
    for (LSApplicationProxy *proxy in installedApps) {
        NSString *identifier = proxy.applicationIdentifier;
        if (identifier.length == 0) {
            continue;
        }

        // 仅显示真正出现在主屏幕的应用，过滤隐藏系统工具和 App 扩展，行为与 AltList 一致。
        NSString *type = proxy.applicationType;
        BOOL isUser = [type isEqualToString:@"User"];
        BOOL isSystem = [type isEqualToString:@"System"];
        if (!isUser && !isSystem) {
            continue;
        }

        if (POApplicationProxyIsHidden(proxy)) {
            continue;
        }

        NSString *name = proxy.localizedName ?: identifier;
        appNamesByIdentifier[identifier] = name;

        if (isUser) {
            appTypeByIdentifier[identifier] = @(QSSectionUser);
            [loadedUser addObject:identifier];
        } else {
            appTypeByIdentifier[identifier] = @(QSSectionSystem);
            [loadedSystem addObject:identifier];
        }
    }

    [self sortIdentifiersByName:loadedUser];
    [self sortIdentifiersByName:loadedSystem];

    userApps = loadedUser;
    systemApps = loadedSystem;

    NSMutableArray *combined = [NSMutableArray arrayWithArray:loadedUser];
    [combined addObjectsFromArray:loadedSystem];
    allApps = combined;
}

-(void)loadSavedFavorites{
    NSUserDefaults *defaults = [self settingsDefaults];
    NSArray *savedFavorites = [[defaults objectForKey:@"favorites"] isKindOfClass:[NSArray class]] ? [defaults objectForKey:@"favorites"] : @[];
    for (NSString *identifier in savedFavorites) {
        if (![identifier isKindOfClass:[NSString class]]) {
            continue;
        }
        if (appTypeByIdentifier[identifier] == nil) {
            continue; // app no longer installed / not a valid home-screen app
        }
        [enabledApps addObject:identifier];
        [userApps removeObject:identifier];
        [systemApps removeObject:identifier];
    }
}

-(void)sortIdentifiersByName:(NSMutableArray<NSString *> *)identifiers{
    [identifiers sortUsingComparator:^NSComparisonResult(NSString *id1, NSString *id2){
        NSString *n1 = appNamesByIdentifier[id1] ?: id1;
        NSString *n2 = appNamesByIdentifier[id2] ?: id2;
        return [n1 localizedCaseInsensitiveCompare:n2];
    }];
}

-(void)persistFavorites{
    NSUserDefaults *defaults = [self settingsDefaults];
    [defaults setObject:enabledApps forKey:@"favorites"];
    [defaults synchronize];
}

#pragma mark - Search

-(void)setupSearchController{
    searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.delegate = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = POLocalizedString(@"Search", @"PullOverXPreferences");

    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

-(void)updateSearchResultsForSearchController:(UISearchController *)controller{
    NSString *query = [controller.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    BOOL nowSearching = (query.length > 0);
    if (nowSearching != isSearching) {
        isSearching = nowSearching;
        // 仅常规三分区布局支持排序。
        [self.tableView setEditing:!isSearching animated:NO];
    }

    [searchResults removeAllObjects];
    if (isSearching) {
        for (NSString *identifier in allApps) {
            if ([enabledApps containsObject:identifier]) {
                continue; // only show apps not yet selected
            }
            NSString *name = appNamesByIdentifier[identifier] ?: identifier;
            if ([name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [identifier rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [searchResults addObject:identifier];
            }
        }
    }

    [self.tableView reloadData];
}

#pragma mark - Helpers

-(NSMutableArray<NSString *> *)arrayForSection:(NSInteger)section{
    switch (section) {
        case QSSectionSelected: return enabledApps;
        case QSSectionUser:     return userApps;
        case QSSectionSystem:   return systemApps;
        default:                return nil;
    }
}

-(NSString *)identifierAtIndexPath:(NSIndexPath *)indexPath{
    if (isSearching) {
        return (indexPath.row < (NSInteger)searchResults.count) ? searchResults[indexPath.row] : nil;
    }
    NSMutableArray<NSString *> *array = [self arrayForSection:indexPath.section];
    return (indexPath.row < (NSInteger)array.count) ? array[indexPath.row] : nil;
}

#pragma mark - Table view data source

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
    return isSearching ? 1 : QSSectionCount;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    if (isSearching) {
        return searchResults.count;
    }
    return [self arrayForSection:section].count;
}

-(NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{
    if (isSearching) {
        return nil;
    }
    switch (section) {
        case QSSectionSelected:
            // 尚未选择应用时显示点按提示。
            return (enabledApps.count == 0)
                ? POLocalizedString(@"Tap an app below to select", @"PullOverXPreferences")
                : POLocalizedString(@"Selected Apps", @"PullOverXPreferences");
        case QSSectionUser:
            return POLocalizedString(@"User Apps", @"PullOverXPreferences");
        case QSSectionSystem:
            return POLocalizedString(@"System Apps", @"PullOverXPreferences");
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *identifier = [self identifierAtIndexPath:indexPath];
    if (identifier == nil) {
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        return cell;
    }

    cell.textLabel.text = appNamesByIdentifier[identifier] ?: identifier;
    cell.detailTextLabel.text = identifier;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    @try {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:identifier format:0 scale:[UIScreen mainScreen].scale];
        cell.imageView.image = icon;
    } @catch (NSException *exception) {
        cell.imageView.image = nil;
    }

    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *identifier = [self identifierAtIndexPath:indexPath];
    if (identifier == nil) {
        return;
    }

    if (isSearching) {
        // 从搜索结果选择后移入收藏。
        [searchResults removeObject:identifier];
        [userApps removeObject:identifier];
        [systemApps removeObject:identifier];
        [enabledApps addObject:identifier];
        [self persistFavorites];
        [self.tableView reloadData];
        return;
    }

    if (indexPath.section == QSSectionSelected) {
        // 取消选择后回到原用户或系统分区，并保持排序。
        [enabledApps removeObject:identifier];
        QSSection origin = (QSSection)[appTypeByIdentifier[identifier] integerValue];
        NSMutableArray<NSString *> *pool = (origin == QSSectionSystem) ? systemApps : userApps;
        [pool addObject:identifier];
        [self sortIdentifiersByName:pool];
    } else {
        // 选择后追加到收藏列表。
        [[self arrayForSection:indexPath.section] removeObject:identifier];
        [enabledApps addObject:identifier];
    }

    [self persistFavorites];
    [self.tableView reloadData];
}

#pragma mark - Reordering (drag handles on the Selected section)

-(BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath{
    return !isSearching && indexPath.section == QSSectionSelected && enabledApps.count > 0;
}

-(NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath{
    // 排序仅允许在“已选择”分区内进行。
    if (proposedDestinationIndexPath.section != QSSectionSelected) {
        return [NSIndexPath indexPathForRow:enabledApps.count - 1 inSection:QSSectionSelected];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath{
    if (sourceIndexPath.section != QSSectionSelected || destinationIndexPath.section != QSSectionSelected) {
        return;
    }
    NSString *element = [enabledApps[sourceIndexPath.row] copy];
    [enabledApps removeObjectAtIndex:sourceIndexPath.row];
    [enabledApps insertObject:element atIndex:destinationIndexPath.row];
    [self persistFavorites];
}

-(UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath{
    return UITableViewCellEditingStyleNone;
}

-(BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath{
    return NO;
}

#pragma mark - Persistence helper

// 用 cfprefsd 域（纯标识符，与 tweak、主设置页同一 suite），三方案通用不写死路径。
- (NSUserDefaults *)settingsDefaults{
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
}

@end
