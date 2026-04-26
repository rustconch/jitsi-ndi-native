//
//  AppData.m
//  SimpleNDI
//
//  Created by Mike Watkins on 3/26/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import "AppData.h"

@implementation NDISourceDesc {
}

-(id) initWithFullName:(NSString*)full AndFriendlyName:(NSString*)friendly AndURL:(NSString*)url {
    if (self = [super init])
    {
        _fullName = [full copy];
        _friendlyName = [friendly copy];
        _urlAddy = [url copy];
    }
    return self;
}

@end

static id sharedInstance;

@implementation AppData {
}
// class instance variables are always initialized to 0

+ (id)inst {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    if ( self = [super init] )
    {
        _hostList = [[NSMutableArray alloc] init];
        _hostSourceList = [[NSMutableArray alloc] init];
    }
    return self;
}

// Destructor
- (void) dealloc
{
    //[self serialize];
}

-(void) setNDISourceInfoNamed:(NSString*)name LocatedAt:(NSString*)url
{
    @synchronized(self)
    {
        _selectedNDISourceName = name;
        _selectedNDISourceURL = url;
        self.selectedNDISourceChangedCount++;
    }
}

-(void) getNDISourceInfoNamed:(NSString**)name LocatedAt:(NSString**)url
{
    @synchronized(self)
    {
        *name = [_selectedNDISourceName copy];
        *url = [_selectedNDISourceURL copy];
    }
}

@end
