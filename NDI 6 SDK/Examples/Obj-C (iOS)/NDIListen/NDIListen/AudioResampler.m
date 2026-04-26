//
//  AudioResampler.m
//  Application.Mac.NDI.StudioMonitor
//
//  Created by Video Engineer on 7/13/17.
//  Copyright © 2017 NewTek, Inc. All rights reserved.
//

#import "AudioResampler.h"
#import <math.h>
#import <assert.h>

const int ResampleResultSrcEmpty = 0;
const int ResampleResultDstFull = 1;

@implementation AudioResampler
{
	// These represent the last 2 samples
	int m_sample_index;
	float m_last_samples[4];
	
	// This is the current sub-sample position
	float m_output_posn;
	float m_output_delta;
	
	// The scaling factor
	float m_scaling;
}

-(id)init
{
	if (self = [super init])
	{
		m_output_posn = 0.0f;
		m_sample_index = -1;
		m_output_delta = 1.0f;
		m_scaling = 1.0f;
		
		// We start out with a history of silence
		memset(m_last_samples, 0, sizeof(m_last_samples));
	}
	return self;
}

-(void)setSourceSampleRate:(float)srcRate andDestRate:(float)dstRate
{
	m_output_delta = srcRate / dstRate;
}

-(void)reset
{
	// Reset all data
	m_sample_index = -1;
	m_output_posn = 0.0f;
	m_output_delta = 1.0f;
}

-(int)getMaxBufferLengthInSamples:(int)numInSamples
{
	return 2 + (int)(ceil(((float)numInSamples) / m_output_delta));
}

-(int)processDst:(struct DstDataDesc*)dst withStride:(int)stride
{
	// Debugging
	assert(stride > 0);
	
	// Quite simple
	for( ; dst->first < dst->second; dst->first+=stride )
		*(dst->first) = 0;
	
	// Always fill the destination completely
	return ResampleResultDstFull;
}

-(int)processSrc:(struct SrcDataDesc*)src toDst:(struct DstDataDesc*)dst withSrcStride:(int)srcStride andWithDstStride:(int)dstStride
{
	// Debugging
	assert((srcStride > 0) && (dstStride > 0));
	
	// Source is NULL?
	if (!(src->first))
		return [self processDst:dst withStride:dstStride];
	
	// Check that there is some work, any work to do
	if ( src->first >= src->second )
		return ResampleResultSrcEmpty;
	if ( dst->first >= dst->second )
		return ResampleResultDstFull;
	
	// Debugging
	assert(m_output_posn >= 0.0f);
	
	// Get the scale
	const float scaling = m_scaling;
	
	// Get the output delta value
	float output_delta = m_output_delta;
	
	// If we are very close to a source sample and the rate is such that we
	// end the buffer very close to a sample then we can take an optimal path
	const int   no_samples   = (int)MIN( ( src->second - src->first )/srcStride, ( dst->second - dst->first )/dstStride );
	const float no_samples_f = (float)no_samples;
	
	// The offset from the first and last samples
	const float start_sample_offset = m_output_posn;
	const float end_sample_offset   = m_output_posn + no_samples_f*( output_delta-1.0f );
	
	// If we have have no history, try to avoid glitches
	if (m_sample_index == -1)
	{
		for (int idx = 0; idx < 4; m_last_samples[idx] = (float)(*(src->first)), idx++);
		m_sample_index = 0;
	}
	
	// The error allowed
	const float eps = 0.01f;
	if ( // Very close to the start sample
		( fabs( start_sample_offset ) < eps ) &&
		// Very close to the end sample, but enough that it got used that we advanced to the next sample
		( end_sample_offset >= 0.0f ) && ( end_sample_offset <= eps ) )
	{
		// Copy
		for( int i=0; i<no_samples; i++ )
			*(dst->first + i*dstStride) = (float)( src->first[ i*srcStride ] ) * scaling;
		
		// Offset the positions
		src->first += no_samples*srcStride;
		dst->first += no_samples*dstStride;
		
		// Update the position exactly
		m_output_posn = end_sample_offset;
		
		// Finished
		if ( src->first >= src->second )
			return ResampleResultSrcEmpty;
		
		return ResampleResultDstFull;
	}
	else
	{
		// Down-sampling.
		while( true )
		{
			// While the current position is out of range
			while( m_output_posn >= 1.0f )
			{
				// Step a new sample in
				m_output_posn -= 1.0f;
				
				// Move this sample in
				m_last_samples[ ( m_sample_index++ ) & 3 ] = (float)(*(src->first));
				src->first += srcStride;
				
				// Finished
				if ( src->first >= src->second )
					return ResampleResultSrcEmpty;
			}
			
			// Get the short history that we use
			const float y0 = m_last_samples[ ( m_sample_index/*-4*/) & 3 ];
			const float y1 = m_last_samples[ ( m_sample_index - 3 ) & 3 ];
			const float y2 = m_last_samples[ ( m_sample_index - 2 ) & 3 ];
			const float y3 = m_last_samples[ ( m_sample_index - 1 ) & 3 ];
			
			// Get the constants
			const float a = ( 3.0f*( y1 - y2 ) - y0 + y3 )*0.5f;
			const float b = 2.0f*y2 + y0 - ( 5.0f*y1 + y3 )*0.5f;
			const float c = ( y2 - y0 )*0.5f;
			
			// Perform cubic interpolation to get these samples
			//assert( m_output_posn>=0 && m_output_posn<=1 );
			*(dst->first) = ( ( ( a*m_output_posn + b )*m_output_posn + c )*m_output_posn + y1 ) * scaling;
			dst->first += dstStride;
			
			// Step the sample
			m_output_posn += output_delta;
			
			// Check whether the output buffer is now full
			if ( dst->first >= dst->second  )
				return ResampleResultDstFull;
		}
	}
}

@end
