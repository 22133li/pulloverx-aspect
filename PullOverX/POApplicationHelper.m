//
//  POApplicationHelper.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "POApplicationHelper.h"
#import <objc/message.h>

static id POValueForKeySafely(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

static void POCollectRecentBundleIdentifiers(id object, NSMutableOrderedSet *bundleIds, NSInteger depth) {
    if (!object || depth > 4 || bundleIds.count >= 30) {
        return;
    }

    if ([object isKindOfClass:[NSString class]]) {
        // 仅保留真实应用标识符，同时过滤 "main"、"home" 等布局标识。
        if ([(NSString *)object containsString:@"."]) {
            [bundleIds addObject:object];
        }
        return;
    }
    if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]] || [object isKindOfClass:[NSOrderedSet class]]) {
        for (id value in object) {
            POCollectRecentBundleIdentifiers(value, bundleIds, depth + 1);
        }
        return;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        POCollectRecentBundleIdentifiers([(NSDictionary *)object allValues], bundleIds, depth + 1);
        return;
    }

    // iOS 13 至 16 的属性名多次变化；这里只做只读 KVC 探测，
    // 仅当 SpringBoard 暴露对应属性时才读取。
    for (NSString *key in @[@"bundleIdentifier", @"displayIdentifier", @"applicationBundleIdentifier", @"applicationIdentifier", @"identifier", @"allItems", @"items", @"displayItems", @"application", @"app"]) {
        id value = POValueForKeySafely(object, key);
        if (value && value != object) {
            POCollectRecentBundleIdentifiers(value, bundleIds, depth + 1);
        }
    }
}

static id POSharedObjectForClass(Class cls) {
    for (NSString *selectorName in @[@"sharedInstance", @"sharedController", @"sharedModel", @"defaultInstance", @"defaultManager"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([cls respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        }
    }
    return nil;
}

@implementation POApplicationHelper

+(NSArray *)recentAppsWithCount:(int)count{
    if (count <= 0) {
        return @[];
    }

    NSMutableOrderedSet *bundleIds = [NSMutableOrderedSet orderedSet];
    NSArray *layoutKeys = @[@"recentAppLayouts", @"appLayouts", @"recentLayouts", @"layouts", @"displayItems", @"items"];
    NSArray *classNames = @[@"SBMainSwitcherViewController", @"SBMainSwitcherControllerCoordinator",
                            @"SBRecentDisplayManager", @"SBFluidSwitcherViewController",
                            @"SBAppSwitcherModel", @"SBRecentAppsController"];

    for (NSString *className in classNames) {
        id source = POSharedObjectForClass(NSClassFromString(className));
        if (!source) {
            continue;
        }

        NSUInteger before = bundleIds.count;
        for (NSString *key in layoutKeys) {
            POCollectRecentBundleIdentifiers(POValueForKeySafely(source, key), bundleIds, 0);
        }
        if (bundleIds.count == before) {
            // 部分 iOS 版本直接由协调器暴露布局对象，而不通过具名集合属性。
            POCollectRecentBundleIdentifiers(source, bundleIds, 0);
        }
        if (bundleIds.count >= (NSUInteger)count) {
            break;
        }
    }

    NSArray *recent = bundleIds.array;
    if (recent.count > (NSUInteger)count) {
        recent = [recent subarrayWithRange:NSMakeRange(0, count)];
    }
    return recent;
}

+(UIImage *)imageForBundleId:(NSString *)bundleId{
    return [self iconImageForIdentifier:bundleId];
}


+(NSString *)frontMostBundleId{
    id app = ((SpringBoard *)[UIApplication sharedApplication])._accessibilityFrontMostApplication;
    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
        return [app bundleIdentifier];
    }
    if ([app respondsToSelector:@selector(displayIdentifier)]) {
        return [app displayIdentifier];
    }
    return nil;
}


+(NSUserDefaults *)settingsDefaults{
    // 用 cfprefsd 域（纯标识符，由系统定位物理位置），tweak 与设置 App 读写同一域。
    // 不写死任何路径 -> rootful/rootless/roothide 三方案通用，roothide 随机 jbroot 也由 cfprefsd 处理。
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
}
+(NSMutableDictionary *)settings{
    return [[[self settingsDefaults] dictionaryRepresentation] mutableCopy];
}
+(void)setSetting:(id)value forKey:(NSString *)key{
    if (key.length == 0) {
        return;
    }
    NSUserDefaults *defaults = [self settingsDefaults];
    if (value) {
        [defaults setObject:value forKey:key];
    } else {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
}

+(NSMutableDictionary *)authorization{
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverxAuthorization"];
    return [[defaults dictionaryRepresentation] mutableCopy];
}




//13 icon gen
+ (UIImage *)iconImageForIdentifier:(NSString *)identifier {
    
    SBIconController *iconController = [NSClassFromString(@"SBIconController") sharedInstance];
    SBIcon *icon = [iconController.model expectedIconForDisplayIdentifier:identifier];
    
    struct CGSize imageSize;
    imageSize.height = 60;
    imageSize.width = 60;
    
    struct SBIconImageInfo imageInfo;
    imageInfo.size  = imageSize;
    imageInfo.scale = [UIScreen mainScreen].scale;
    imageInfo.continuousCornerRadius = 12;
    
    return [icon generateIconImageWithInfo:imageInfo];
}


@end
