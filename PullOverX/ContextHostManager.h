#import <Foundation/Foundation.h>
#import "ContextInterfaces.h"
#import "headers.h"

@class ContextHostManager;
@protocol ContextHostManagerExternalSceneDelegate <NSObject>
-(void)contextManager:(id)manager scene:(FBScene *)scene sceneStackDidChange:(UIView *)sceneStack;
-(void)contextManager:(id)manager scene:(FBScene *)scene externalSceneStackDidChange:(UIView *)sceneStack;
@optional
// The host manager has no UIWindow of its own. Its delegate supplies the
// logical hosting canvas; PullOver deliberately uses a portrait canvas when
// displaying portrait-oriented apps in landscape.
-(CGSize)contextManagerPreferredSceneStackSize:(id)manager;
@end

@interface ContextHostManager : NSObject
@property (nonatomic, weak) id <ContextHostManagerExternalSceneDelegate> sceneDelegate;
@property (nonatomic, copy, readonly) NSString *activeHostedBundleId;
+ (id)sharedInstance;

// Used by SpringBoard hooks to keep PullOver-hosted scenes foregrounded so
// camera/media services do not treat them as fully backgrounded.
+ (BOOL)shouldKeepForegroundForIdentifier:(NSString *)identifier;
+ (BOOL)shouldKeepForegroundForScene:(FBScene *)scene;
+ (NSString *)activeHostedBundleId;

-(UIView *)hostViewForBundleID:(NSString *)bundleId;

// End the current PullOver hosting session and restore its scene to the normal
// background state. The retained host view may remain in PullOver's hierarchy
// as a visual snapshot, but it no longer owns the app's foreground scene.
-(void)stopHosting;
-(void)stopHostingView:(__weak UIView *)view forBundleId:(NSString *)bundleId;
-(BOOL)isHostingScene:(FBScene *)scene forBundleId:(NSString *)bundleId;
-(BOOL)isHostingBundleReady:(NSString *)bundleId;
-(BOOL)isHostViewHosting:(UIView *)hostView;

// Background a specific app's scene (setForeground:NO) without disturbing the
// scene currently being hosted/observed. Used to release the app we switched
// away from once the new app's content is on screen.
-(void)backgroundSceneForBundleId:(NSString *)bundleId;


@end
