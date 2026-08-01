//
//  POApplicationHelper.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "headers.h"

@interface NSString (MyAdditions)
- (NSString *)md5;
@end

@interface NSData (MyAdditions)
- (NSString *)md5;
@end


@interface POApplicationHelper : NSObject

+(NSArray *)recentAppsWithCount:(int)count;
+(UIImage *)imageForBundleId:(NSString *)bundleId;
+(NSString *)frontMostBundleId;

+(NSArray *)recentAppsWithCount:(int)count;
+(UIImage *)imageForBundleId:(NSString *)bundleId;
+(NSString *)frontMostBundleId;

+(NSUserDefaults *)settingsDefaults;
+(NSMutableDictionary *)settings;
+(void)setSetting:(id)value forKey:(NSString *)key;

+(NSMutableDictionary *)authorization;

+(UIImage *)iconImageForIdentifier:(NSString *)identifier;

@end
