//
//  AudioResampler.h
//  Application.Mac.NDI.StudioMonitor
//
//  Created by Video Engineer on 7/13/17.
//  Copyright © 2017 NewTek, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

struct DstDataDesc
{
	float* first;
	const float* second;
};
struct SrcDataDesc
{
	const float* first;
	const float* second;
};

extern const int ResampleResultSrcEmpty;
extern const int ResampleResultDstFull;

@interface AudioResampler : NSObject

-(id)init;
-(void)setSourceSampleRate:(float)srcRate andDestRate:(float)dstRate;
-(void)reset;
-(int)getMaxBufferLengthInSamples:(int)numInSamples;

-(int)processSrc:(struct SrcDataDesc*)src toDst:(struct DstDataDesc*)dst withSrcStride:(int)srcStride andWithDstStride:(int)dstStride;

@end
