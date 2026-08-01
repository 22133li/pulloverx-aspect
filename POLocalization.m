//
//  POLocalization.m
//  PullOver X
//

#import "POLocalization.h"
#import "POPPath.h"

NSBundle *POLocalizationBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = POPPath(@"/Library/PreferenceBundles/PullOverXPreferences.bundle");
        bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

NSString *POLocalizedString(NSString *key, NSString *table) {
    NSBundle *bundle = POLocalizationBundle();
    if (!bundle) {
        return key;
    }

    return [bundle localizedStringForKey:key value:key table:table];
}
