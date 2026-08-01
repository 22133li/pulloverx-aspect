//
//  POLocalization.h
//  PullOver X
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The preference bundle is the shared localization resource for both targets.
NSBundle *POLocalizationBundle(void);

/// Looks up a key in one of the bundle's .strings tables.
NSString *POLocalizedString(NSString *key, NSString *table);

NS_ASSUME_NONNULL_END
