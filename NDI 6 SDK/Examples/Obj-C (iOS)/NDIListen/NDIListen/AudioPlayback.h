//
//  AudioPlayback.h
//  Application.Mac.NDI.StudioMonitor
//
//  Created by Video Engineer on 7/13/17.
//  Copyright © 2017 NewTek, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface AudioPlayback : NSObject

@property (nonatomic) bool mute;
@property (nonatomic) int sourceChangedCounter;
	
-(void) shutdown;

@end
