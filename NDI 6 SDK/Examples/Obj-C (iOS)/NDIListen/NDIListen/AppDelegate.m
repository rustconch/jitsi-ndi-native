//
//  AppDelegate.m
//  SimpleNDI
//
//  Created by Mike Watkins on 3/26/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import "AppDelegate.h"
#import "AudioPlayback.h"
// NDI
#import "../../../../Include/Processing.NDI.Lib.h"

@interface AppDelegate ()
{
NDIlib_find_instance_t _finder;
}

@end

@implementation AppDelegate

- (id)init
{
    if ( self = [super init] )
    {
        _theModel = [AppData inst];
        [ self startNDI ];
        // ToDo : Show Alert if I can't startup NDI
        
    }
    return self;
}

// Destructor
- (void) dealloc
{
    if (_finder)
        NDIlib_find_destroy(_finder);
    
    // Not required, but nice
    NDIlib_destroy();
    
    //[super dealloc];    // ARC forbids ;)
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    return YES;
}


- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    
    _theModel.audioPlayer.mute = true;
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    _theModel.audioPlayer.mute = false;
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

- (bool)startNDI
{
    // We can now run as usual
    if (!NDIlib_initialize())
    {
        printf("Cannot run NDI.");
        assert(false);
        return false;
    }
    
    [self findSources];
    
    return true;
}

-(void)findSources
{
    if (!_finder)
    {
        NDIlib_find_create_t finder_create_params;
        finder_create_params.p_groups = NULL;
        finder_create_params.p_extra_ips = NULL;
        finder_create_params.show_local_sources = true;
        _finder = NDIlib_find_create_v2(&finder_create_params);
    }
    
    uint32_t num_sources = 0;
    const NDIlib_source_t* p_sources = NDIlib_find_get_current_sources(_finder, &num_sources);
    
    [_theModel.hostList removeAllObjects];
    [_theModel.hostSourceList removeAllObjects];
    
    NSString *group = @"";
    NSMutableArray *groupSourceList = nil;
    for (int i = 0; i < num_sources; i++)
    {
        NSString *fullString = [NSString stringWithUTF8String:p_sources[i].p_ndi_name];
        NSRange endGroup = [fullString rangeOfString:@" ("];
        if ((endGroup.location != NSNotFound) && (fullString.length > (endGroup.location + endGroup.length)))
        {
            NSString *newGroup = [fullString substringToIndex:endGroup.location];
            NSString *newChannel = [fullString substringFromIndex:endGroup.location + endGroup.length];
            NSRange endChannel = [newChannel rangeOfString:@")"];
            if ((endChannel.location != NSNotFound) && (endChannel.location > 0))
            {
                newChannel = [newChannel substringToIndex:endChannel.location];
                
                if (NO == [newGroup isEqualToString:group])
                {
                    group = newGroup;
                    
                    [_theModel.hostList addObject:group];
                    
                    groupSourceList = [[NSMutableArray alloc] init];
                    [_theModel.hostSourceList addObject:groupSourceList];
                }
                
                //[groupSourceList addObject:newChannel];
                NSString *url = [NSString stringWithUTF8String:p_sources[i].p_url_address];
                NDISourceDesc *ndiSrcDesc = [[NDISourceDesc alloc] initWithFullName:fullString AndFriendlyName:newChannel AndURL:url];
                [groupSourceList addObject:ndiSrcDesc];
            }
            
        }
    }
}


@end
