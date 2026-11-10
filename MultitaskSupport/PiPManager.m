//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "LCMediaPiPController.h"
#include "DecoratedAppSceneViewController.h"
#include "../LiveContainer/utils.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic) AppSceneViewController* displayingVC;
@property(nonatomic) NSUInteger startGeneration;
@property(nonatomic) BOOL observingBounds;
@property(nonatomic) BOOL containerPiPActive, scenePlaybackProtected;
@property(nonatomic, strong) LCMediaPiPController *mediaController;
@end


@implementation PiPManager
API_AVAILABLE(ios(16.0))
static PiPManager* sharedInstance = nil;

+ (instancetype)shared {
    if(!sharedInstance)
        sharedInstance = [[self alloc] init];
    return sharedInstance;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    return (id)self.displayingVC.delegate;
}

- (BOOL)isPiP {
    return self.pipController.isPictureInPictureActive;
}

- (BOOL)isPiPWithVC:(AppSceneViewController*)vc {
    return (self.pipController.isPictureInPictureActive || self.mediaController != nil) && self.displayingVC == vc;
}

- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc {
    return (self.pipController.isPictureInPictureActive || self.mediaController != nil) && self.displayingDecoratedVC == vc;
}

- (instancetype)init {
    return [super init];
}

- (void)startPiPWithVC:(AppSceneViewController*)vc {
    if (!vc.isAppRunning || !vc.view.window || !vc.view.superview) return;
    NSUInteger generation = ++self.startGeneration;
    AVPictureInPictureController *previous = self.pipController;
    BOOL replacingActivePiP = previous.isPictureInPictureActive;
    [previous stopPictureInPicture];
    if (previous && previous == self.pipController && self.displayingVC) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:previous];
    }
    previous.delegate = nil;
    if (self.pipController == previous) self.pipController = nil;
    self.displayingVC = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(replacingActivePiP * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.startGeneration || !vc.isAppRunning || !vc.view.window || !vc.view.superview) return;
        self.displayingVC = vc;
        NSDictionary *media = vc.containerMediaPlayback;
        if (media && [self startMediaPictureInPictureWithVC:vc descriptor:media]) return;
        LCActivatePictureInPictureAudio();
        self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];
        self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
        if(vc.usesHostingControllerAPI) {
            self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
            //self.pipVideoCallContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.pipVideoCallContentView.layer.anchorPoint = CGPointMake(0, 0);
            self.pipVideoCallContentView.layer.position = CGPointMake(0, 0);
            [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
        } else {
            self.pipVideoCallContentView = vc.contentView;
        }
        AVPictureInPictureControllerContentSource* contentSource =  [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.pipController.delegate = self;
        [self.pipController setValue:@1 forKey:@"controlsStyle"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.startGeneration || !vc.isAppRunning) return;
            [self.pipController startPictureInPicture];
        });
    });

}

- (BOOL)startMediaPictureInPictureWithVC:(AppSceneViewController *)vc descriptor:(NSDictionary *)descriptor {
    LCMediaPiPController *media = [[LCMediaPiPController alloc] initWithView:vc.view descriptor:descriptor delegate:self];
    if (!media.controller) { [media invalidate]; return NO; }
    self.mediaController = media;
    self.pipController = media.controller;
    self.pipVideoCallContentView = nil;
    self.pipVideoCallViewController = nil;
    __weak typeof(self) weakSelf = self;
    __weak LCMediaPiPController *weakMedia = media;
    media.stateDidChange = ^{
        PiPManager *manager = weakSelf;
        LCMediaPiPController *current = weakMedia;
        if (!manager || !current || manager.mediaController != current) return;
        [manager.displayingVC setContainerMediaPlaybackState:current.playbackState
                                     pictureInPictureActive:manager.containerPiPActive];
    };
    media.failedToStart = ^(NSError *error) {
        PiPManager *manager = weakSelf;
        LCMediaPiPController *current = weakMedia;
        if (!manager || !current || manager.mediaController != current) return;
        [manager pictureInPictureController:manager.pipController failedToStartPictureInPictureWithError:error];
    };
    // The guest acknowledges its pause before the native player starts audio.
    [vc setContainerMediaPlaybackState:media.playbackState pictureInPictureActive:NO];
    [media start];
    return YES;
}

- (void)containerMediaPlaybackDidChangeForVC:(AppSceneViewController *)vc {
    if (vc != self.displayingVC || !self.mediaController) return;
    NSDictionary *descriptor = vc.containerMediaPlayback;
    if (!descriptor || ![descriptor[@"session"] isEqual:self.mediaController.sessionIdentifier]) {
        // Losing the owning route/connection must silence its native player
        // immediately; it cannot keep playing during an asynchronous stop.
        ++self.startGeneration;
        [self finishMediaPictureInPicture];
        return;
    }
    [self.mediaController updateDescriptor:descriptor];
}

- (void)stopPiP {
    ++self.startGeneration;
    AVPictureInPictureController *controller = self.pipController;
    BOOL wasActive = controller.isPictureInPictureActive;
    [controller stopPictureInPicture];
    if (controller && !wasActive && controller == self.pipController) {
        [self pictureInPictureControllerDidStopPictureInPicture:controller];
        controller.delegate = nil;
        if (self.pipController == controller) self.pipController = nil;
    }
}

- (void)protectGuestSceneForPictureInPicture {
    if (self.scenePlaybackProtected) return;
    self.scenePlaybackProtected = YES;
    [self.displayingVC setBackgroundNotificationEnabled:false];
    self.displayingVC.shouldIgnoreSceneUpdates = YES;
}

- (void)restoreGuestSceneAfterPictureInPicture {
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    if (!self.scenePlaybackProtected) return;
    self.scenePlaybackProtected = NO;
    [self.displayingVC setBackgroundNotificationEnabled:true];
}

// PIP delegate
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (!pictureInPictureController || pictureInPictureController != self.pipController) return;
    self.containerPiPActive = YES;
    [self.displayingVC setContainerPictureInPictureActive:YES];
    [self protectGuestSceneForPictureInPicture];
    [self.displayingDecoratedVC minimizeWindowPiP];
    if (self.mediaController) return;
    if(self.displayingVC.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
        self.pipVideoCallViewController.additionalSafeAreaInsets = self.displayingVC.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:self.displayingVC.contentView];
    } else {
        self.displayingVC.contentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    [self.pipVideoCallViewController.view.layer addObserver:self
                                forKeyPath:@"bounds"
                                   options:NSKeyValueObservingOptionNew
                                   context:NULL];
    self.observingBounds = YES;
    self.pipVideoCallViewController.preferredContentSize = self.displayingVC.view.bounds.size;
}



- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (!pictureInPictureController || pictureInPictureController != self.pipController) return;
    self.containerPiPActive = YES;
    [self.mediaController didStart];
    [self.displayingVC setContainerPictureInPictureActive:YES];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (!pictureInPictureController || pictureInPictureController != self.pipController) return;
    [self.mediaController willStop];
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (!pictureInPictureController || pictureInPictureController != self.pipController) return;
    if (self.mediaController) {
        [self finishMediaPictureInPicture];
        return;
    }
    self.containerPiPActive = NO;
    [self restoreGuestSceneAfterPictureInPicture];
    [self stopObservingBounds];
    if (self.displayingVC.contentView) [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    [self.displayingVC setContainerPictureInPictureActive:NO];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)finishMediaPictureInPicture {
    if (!self.mediaController) return;
    NSMutableDictionary *state = [self.mediaController.playbackState mutableCopy];
    state[@"mediaActive"] = @NO;
    self.containerPiPActive = NO;
    [self.mediaController invalidate];
    self.mediaController = nil;
    self.pipController = nil;
    [self restoreGuestSceneAfterPictureInPicture];
    [self.displayingDecoratedVC unminimizeWindowPiP];
    [self.displayingDecoratedVC updateVerticalConstraints];
    [self.displayingVC setContainerMediaPlaybackState:state pictureInPictureActive:NO];
    self.displayingVC = nil;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
 restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    UIView *view = self.displayingDecoratedVC.view;
    if (!controller || controller != self.pipController || !self.displayingVC.isAppRunning || !view.superview) {
        completionHandler(NO);
        return;
    }
    [self.displayingDecoratedVC unminimizeWindowPiP];
    [view.superview bringSubviewToFront:view];
    [view layoutIfNeeded];
    completionHandler(YES);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    if (!pictureInPictureController || pictureInPictureController != self.pipController) return;
    [self.displayingDecoratedVC unminimizeWindowPiP];
    [self pictureInPictureControllerDidStopPictureInPicture:pictureInPictureController];
    NSLog(@"[LCPiP] Start failed (%@, %ld)", error.domain, (long)error.code);
}

- (void)stopObservingBounds {
    if (!self.observingBounds) return;
    [self.pipVideoCallViewController.view.layer removeObserver:self forKeyPath:@"bounds"];
    self.observingBounds = NO;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    CGRect rect = [change[@"new"] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / self.displayingVC.contentView.bounds.size.width/scale,rect.size.height /self.displayingVC.contentView.bounds.size.height/scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end
