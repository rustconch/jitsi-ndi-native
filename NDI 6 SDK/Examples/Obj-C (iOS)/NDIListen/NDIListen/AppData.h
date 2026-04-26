//
//  AppData.h
//  SimpleNDI
//
//  Created by Mike Watkins on 3/26/19.
//  Copyright © 2019 NewTek. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NDISourceDesc : NSObject {
}

@property (readonly, nonatomic) NSString *fullName;
@property (readonly, nonatomic) NSString *friendlyName;
@property (readonly, nonatomic) NSString *urlAddy;

-(id) initWithFullName:(NSString*)full AndFriendlyName:(NSString*)friendly AndURL:(NSString*)url;

@end

// Forward decl of AudioPlayback class
@class AudioPlayback;

@interface AppData : NSObject {
}
// class instance variables are always initialized to 0

@property NSMutableArray *hostList;
@property NSMutableArray *hostSourceList;

@property NSMutableArray *currHostSourceList;

@property (nonatomic) AudioPlayback *audioPlayer;

@property (readonly, nonatomic) NSString *selectedNDISourceName;
@property (readonly, nonatomic) NSString *selectedNDISourceURL;
@property (atomic) int selectedNDISourceChangedCount;

-(void) setNDISourceInfoNamed:(NSString*)name LocatedAt:(NSString*)url;
-(void) getNDISourceInfoNamed:(NSString**)name LocatedAt:(NSString**)url;

+ (id)inst;

@end
