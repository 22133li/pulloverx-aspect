#import <Foundation/Foundation.h>
#import "ContextInterfaces.h"
#import "headers.h"

@class ContextHostManager;
@protocol ContextHostManagerExternalSceneDelegate <NSObject>
-(void)contextManager:(id)manager scene:(FBScene *)scene sceneStackDidChange:(UIView *)sceneStack;
-(void)contextManager:(id)manager
                scene:(FBScene *)scene
externalSceneStackDidChange:(UIView *)sceneStack
   containsKeyboardLayer:(BOOL)containsKeyboardLayer;
@optional
// The host manager has no UIWindow of its own. Its delegate supplies the
// logical hosting canvas; PullOver deliberately uses a portrait canvas when
// displaying portrait-oriented apps in landscape.
-(CGSize)contextManagerPreferredSceneStackSize:(id)manager;
// The logical canvas has an orientation contract as well as a size contract.
// A backgrounded app can retain the orientation it had when it left the
// foreground; normalize the source scene before its layer is hosted.
-(UIInterfaceOrientation)contextManagerPreferredHostedInterfaceOrientation:(id)manager;
@end

@interface ContextHostManager : NSObject
@property (nonatomic, weak) id <ContextHostManagerExternalSceneDelegate> sceneDelegate;
@property (nonatomic, copy, readonly) NSString *activeHostedBundleId;
+ (id)sharedInstance;

// Used by SpringBoard hooks to keep PullOver-hosted scenes foregrounded.
+ (BOOL)shouldKeepForegroundForIdentifier:(NSString *)identifier;
+ (BOOL)shouldKeepForegroundForScene:(FBScene *)scene;
+ (NSString *)activeHostedBundleId;
// Called from the SpringBoard FBScene update hooks. It keeps an incoming
// system orientation update from breaking PullOver's virtual host orientation
// while the scene is actively hosted.
+ (void)applyHostedInterfaceOrientationToSettings:(id)settings forScene:(FBScene *)scene;

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
