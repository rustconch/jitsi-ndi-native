//
//  AppDelegate.h
//  SimpleNDI
//
//  Created by Mike Watkins on 3/26/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "AppData.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

@property (nonatomic, readonly) AppData* theModel;

-(void)findSources;

@end

