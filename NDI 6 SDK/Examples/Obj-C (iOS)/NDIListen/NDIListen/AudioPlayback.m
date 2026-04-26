//
//  AudioPlayback.m
//  Application.Mac.NDI.StudioMonitor
//
//  Created by Video Engineer on 7/13/17.
//  Copyright © 2017 NewTek, Inc. All rights reserved.
//

// Need me some AudioToolbox
#include <AudioToolbox/AudioQueue.h>
#include <AVFoundation/AVFoundation.h>

// Myself
#import "AudioPlayback.h"

// AppData singleton
#import "AppData.h"

// The AppDelegate to access the NDIlib
#import "AppDelegate.h"

// Audio Resampler
#import "AudioResampler.h"

// NDI
#import "../../../../Include/Processing.NDI.Lib.h"

#define kNumBuffers 3
#define kNumChannels 2
#define kSampleRate 48000
#define kNumSamplesPerBuffer 1600

// Max is 64
#define kNumAudioPacketsForBuffering 32

@interface AudioPlayback(private)
-(void)setupAudioFormat;
-(void)startPlayback;
-(void)stopPlayback;
@end

@implementation AudioPlayback
{
	// My properties
	bool _mute;
	int _sourceChangedCounter;
	
	// The source changed counter that corresponds to the source being listened to now
	int _activeSourceChangedCounter;
	
	// The one and only application data model
	AppData *_theModel;
	
	// NDI
	NDIlib_recv_instance_t m_pNDI_recv;
	
	// Am I currently doing playback?
	bool _isPlaying;
	// Has the capture queue been primed for a new connection
	bool _newConnectionPrimed;
	
	// Audio Toolbox
	const int _sampleRate;
	AudioStreamBasicDescription  dataFormat;
	AudioQueueRef                queue;
	AudioQueueBufferRef          buffers[kNumBuffers];
	
	// Intermediate buffers that we've resampled into
	Float32 *p_pcm_data;
	uint32_t pcm_data_capacity;
	uint32_t pcm_data_size;
	uint32_t pcm_data_cursor;	// Offset to "left over" data not queued for playback last time
	
	AudioResampler* _resamplers[kNumChannels];
}

-(void)setMute:(bool)value
{
	_mute = value;
	
	// If muted stop playback else start playback back up
	if (_mute)
	{
		if (_isPlaying)
			[self stopPlayback];
	}
	else if (!_isPlaying)
	{
		const bool sourceSpecified = _theModel.selectedNDISourceName.length || _theModel.selectedNDISourceURL.length;
		if (sourceSpecified)
			[self startPlayback];
	}
}

-(void)setSourceChangedCounter:(int)value
{
	_sourceChangedCounter = value;
	
	// Start playback if it hasn't been started already
	bool sourceSpecified = _theModel.selectedNDISourceName.length || _theModel.selectedNDISourceURL.length;
	if (!sourceSpecified)
		[self stopPlayback];
	else if (!_isPlaying && !_mute)
		[self startPlayback];
}
	
-(id)init
{
	if (self = [super init])
	{
		_theModel = [AppData inst];
        
        /*
        // Configure the audio session
        AVAudioSession* audioSession = [AVAudioSession sharedInstance];
        BOOL sessionSuccess = [audioSession setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDuckOthers error:nil];
        assert(sessionSuccess == YES);
        
        NSError *pErr = nil;
        BOOL startSuccess = [audioSession setActive:YES error:&pErr];
        */
        
		// Setup the audio stream basic description for Audio Toolbox
		[self setupAudioFormat];
		
		// and create appropriate resamples for that format
		for (int i=0; i<kNumChannels; i++)
			_resamplers[i] = [[AudioResampler alloc] init];
	}
	return self;
}
	
-(void)dealloc
{
	// Cleanup
	[self stopPlayback];
	
	for (int i=0; i<kNumChannels; i++)
		_resamplers[i] = nil;
}
	
// Fills an empty buffer with data and sends it to the speaker
void AudioOutputCallback(void * inUserData,
							AudioQueueRef outAQ,
							AudioQueueBufferRef outBuffer)
{
	AudioPlayback *refObj = (__bridge AudioPlayback*) inUserData;
	
	[refObj AudioOutputCallbackImp:outAQ:outBuffer];
}
	
-(void)AudioOutputCallbackImp:(AudioQueueRef)outAQ :(AudioQueueBufferRef)outBuffer
{
	// Enqueue the last resampled audio if available otherwise insert silence
	if (pcm_data_cursor >= pcm_data_size)
	{
		memset(outBuffer->mAudioData, 0, outBuffer->mAudioDataBytesCapacity);
		outBuffer->mAudioDataByteSize = outBuffer->mAudioDataBytesCapacity;
		
		OSStatus status = AudioQueueEnqueueBuffer(queue, outBuffer, 0, NULL);
		if (status != 0)
			printf("enqueuebuffer result %d \n", (int)status);
		/*
        else
			printf("inserted silence \n");
        */
	}
	else
	{
		// Sanity check
		assert(p_pcm_data);
		// The min of the dest buffer size the and size of the data remaining in the source buffer
		const UInt32 num_copy_bytes = MIN(outBuffer->mAudioDataBytesCapacity, pcm_data_size - pcm_data_cursor);
		memcpy(outBuffer->mAudioData, ((int8_t*)p_pcm_data) + pcm_data_cursor, num_copy_bytes);
		outBuffer->mAudioDataByteSize = num_copy_bytes;
		
		OSStatus status = AudioQueueEnqueueBuffer(queue,
												  outBuffer,
												  0,
												  NULL);
		if (status != 0)
			printf("enqueuebuffer result %d \n", (int)status);
		
		pcm_data_cursor += num_copy_bytes;
	}
	
	// Check for a change in the NDI source and make the connection if needed
	int polledSourceChangedCounter = _theModel.selectedNDISourceChangedCount;
	if (_activeSourceChangedCounter != polledSourceChangedCounter)
	{
		// Destroy my last connection and return if there is no new connection
		if (m_pNDI_recv)
		{
			NDIlib_recv_destroy(m_pNDI_recv);
			m_pNDI_recv = NULL;
		}
		
		// Create my new connection
		NSString *url = nil;
		NSString *name = nil;
		[_theModel getNDISourceInfoNamed:&name LocatedAt:&url];
		
		NDIlib_source_t ndi_source = { 0 };
		ndi_source.p_ip_address = [url UTF8String];
		ndi_source.p_ndi_name = [name UTF8String];
		
		NDIlib_recv_create_v3_t NDI_recv_create_desc =
		{ ndi_source, NDIlib_recv_color_format_fastest, NDIlib_recv_bandwidth_audio_only, true };
		
		// Create the receiver
		m_pNDI_recv = NDIlib_recv_create_v3(&NDI_recv_create_desc);
		assert(m_pNDI_recv);
		
		// Reset the resamplers
		for (int i=0; i<kNumChannels; i++)
			[_resamplers[i] reset];
		
		// Mark that the new connection needs priming
		_newConnectionPrimed = false;
		
		// Store the change counter corresponding to the active source
		_activeSourceChangedCounter = polledSourceChangedCounter;
	}
	
	// If I've enqueued all of the previously captured audio then
	// Capture new audio and resample it
	if (pcm_data_cursor >= pcm_data_size)
	{
		if (!_newConnectionPrimed)
		{
			NDIlib_recv_queue_t audio_queued;
			audio_queued.audio_frames = 0;
			NDIlib_recv_get_queue(m_pNDI_recv, &audio_queued);
			_newConnectionPrimed = (audio_queued.audio_frames > kNumAudioPacketsForBuffering);
		}
		
		if (_newConnectionPrimed)
		{
			// Start with a timeout of half a queued up buffer's worth of time
            uint32_t timeout_in_ms = (kNumSamplesPerBuffer * 500) / ((uint32_t)(dataFormat.mSampleRate));
			NDIlib_audio_frame_v2_t audio_frame;
			NDIlib_frame_type_e type_captured;
			// Don't let a captured status change indicator result in a dropped frame
			do
			{
				type_captured = NDIlib_recv_capture_v2(m_pNDI_recv, NULL, &audio_frame, NULL, timeout_in_ms);
				// This rounds down so in the crazy case of there being a bunch of status change messages we still wait less than 2 full queued up buffer's worth of time
				timeout_in_ms /= 2;
			}
			while (type_captured == NDIlib_frame_type_status_change);
			
			if (NDIlib_frame_type_audio == type_captured)
			{
                /*
                NDIlib_recv_queue_t audio_queued;
                audio_queued.audio_frames = 0;
                NDIlib_recv_get_queue(m_pNDI_recv, &audio_queued);
				printf("Audio data received (%d samples). Captured frames %d. \n", audio_frame.no_samples, audio_queued.audio_frames);
                */
			
				// Set the sample rates for all channel resamplers
				for (int i=0; i<kNumChannels; i++)
					[_resamplers[i] setSourceSampleRate:audio_frame.sample_rate andDestRate:kSampleRate];
		
				// Get the largest possible number of "resampled" samples
				const uint32_t allocSamples = [_resamplers[0] getMaxBufferLengthInSamples:audio_frame.no_samples];
		
				const uint32_t allocBytes = (uint32_t)(allocSamples * kNumChannels * sizeof(Float32));
				if (allocBytes > pcm_data_capacity)
				{
					p_pcm_data = (Float32*)realloc(p_pcm_data, allocBytes);
					pcm_data_capacity = allocBytes;
				}
		
				// Special case for mono
				if (audio_frame.no_channels == 1)
				{
					const float *srcChannelPlaneStart = audio_frame.p_data;
					struct SrcDataDesc srcData = { srcChannelPlaneStart, srcChannelPlaneStart + audio_frame.no_samples };
					
					struct DstDataDesc dstData = { p_pcm_data, p_pcm_data + (allocSamples * kNumChannels)};
					int result = [_resamplers[0] processSrc:&srcData toDst:&dstData withSrcStride:1 andWithDstStride:kNumChannels];
					assert(result == ResampleResultSrcEmpty);
					
					const long num_dst_samples = allocSamples - ((dstData.second - dstData.first) / kNumChannels);
					pcm_data_size = (uint32_t)(num_dst_samples * kNumChannels * sizeof(Float32));
					
					// Memcpy mono into dest channel 2
					Float32 *p_dstData = p_pcm_data;
					for (long sample = 0; sample < num_dst_samples; sample++)
					{
						p_dstData[1] = p_dstData[0];
						p_dstData += kNumChannels;
					}
				}
				else
				{
					for (int i=0; i<kNumChannels; i++)
					{
						const float *srcChannelPlaneStart = audio_frame.p_data + (i * audio_frame.no_samples);
						struct SrcDataDesc srcData = { srcChannelPlaneStart,
														srcChannelPlaneStart + audio_frame.no_samples };
			
						struct DstDataDesc dstData = { p_pcm_data + i, (p_pcm_data + i) + (allocSamples * kNumChannels)};
						int result = [_resamplers[i] processSrc:&srcData toDst:&dstData withSrcStride:1 andWithDstStride:kNumChannels];
						assert(result == ResampleResultSrcEmpty);
			
						const long num_dst_samples = allocSamples - ((dstData.second - dstData.first) / kNumChannels);
						pcm_data_size = (uint32_t)(num_dst_samples * kNumChannels * sizeof(Float32));
					}
				}
				
                // Free the audio
                NDIlib_recv_free_audio_v2(m_pNDI_recv, &audio_frame);

				pcm_data_cursor = 0;
			}
			else
            {
				printf("Couldn't capture audio fast enough. Bufferring...\n");
                
                // Mark that the connection needs priming (bufferring)
                _newConnectionPrimed = false;
            }
		}
	}
	
}
	
-(void)startPlayback
{
	// Precondition sanity check
	assert(!_isPlaying);
	
	// Allocate a new AudioToolbox Audio Queue
	// Allocate the audio queue and the buffers
	OSStatus status;
	status = AudioQueueNewOutput(&dataFormat,
								 AudioOutputCallback,
								 (__bridge_retained void *) self,
								 NULL /*CFRunLoopGetCurrent()*/, // NULL specifies that the callback will be invoked whenever a sound buffer becomes exhausted
								 kCFRunLoopCommonModes,
								 0,
								 &queue);
	
	// Allocate and initialize Audio Queue playback buffers
	if (status == 0)
	{
		// Allocate and initialize playback buffers
		for (int i = 0; i < kNumBuffers; i++)
		{
			const UInt32 buffer_size = kNumSamplesPerBuffer * dataFormat.mBytesPerFrame;
			AudioQueueAllocateBuffer(queue, buffer_size, &buffers[i]);
			
			memset(buffers[i]->mAudioData, 0, buffer_size);
			buffers[i]->mAudioDataByteSize = buffer_size;
			
			OSStatus status = AudioQueueEnqueueBuffer(queue, buffers[i], 0, NULL);
			assert(status == 0);
		}
		
		// Prime the playback buffers
        /*
		UInt32 num_frames_prepared = 0;
		status = AudioQueuePrime(queue, kNumSamplesPerBuffer * kNumBuffers, &num_frames_prepared);
		printf("Num frames primed is %d !!! \n", (int)num_frames_prepared);
		*/
		// Mark that the new connection needs priming too
		_newConnectionPrimed = false;
		_activeSourceChangedCounter = 0;
		
		// Start the audio queue
		status = AudioQueueStart(queue, NULL);
		if (status == 0)
			printf("Playing \n");
		else
			printf("AudioQueueStart returned status %d \n", (int)status);
		
		// Store that I'm currently doing playback
		_isPlaying = true;
	}
}
	
-(void)stopPlayback
{
	// Stop the audio queue callbacks
	if (queue)
	{
		AudioQueueStop(queue, true);
	
		for(int i = 0; i < kNumBuffers; i++)
		{
			if (buffers[i])
			{
				AudioQueueFreeBuffer(queue, buffers[i]);
				buffers[i] = NULL;
			}
		}
	
		AudioQueueDispose(queue, true);
		queue = NULL;
	}
	
	// Destroy the receiver
	if (m_pNDI_recv)
	{
		NDIlib_recv_destroy(m_pNDI_recv);
		m_pNDI_recv = NULL;
	}
	
	// Free the intermediate memory
	free(p_pcm_data);
	p_pcm_data = NULL;
	pcm_data_size = pcm_data_cursor = pcm_data_capacity = 0;
	
	// I'm no longer playing anymore
	_isPlaying = false;
}
	
-(void) shutdown
{
	[self stopPlayback];
}
	
-(void)setupAudioFormat
{
	dataFormat.mSampleRate = kSampleRate;
	dataFormat.mFormatID = kAudioFormatLinearPCM;
	dataFormat.mFramesPerPacket = 1;
	dataFormat.mChannelsPerFrame = kNumChannels;
	dataFormat.mBytesPerFrame = kNumChannels * 4;
	dataFormat.mBytesPerPacket = kNumChannels * 4;
	dataFormat.mBitsPerChannel = 32;
	dataFormat.mReserved = 0;
	dataFormat.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
}

@end

