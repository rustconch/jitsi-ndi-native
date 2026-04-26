#include <csignal>
#include <cstddef>
#include <cstdio>
#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include <stdlib.h>
#include <dlfcn.h>

#include <AudioToolbox/AudioQueue.h>

#include "Processing.NDI.Lib.h"

static std::atomic<bool> exit_loop(false);
static void sigint_handler(int)
{	exit_loop = true;
}

//////////////////////////////////////////////////////////////////////////////////////////////
// Struct defining playback state
#define NUM_BUFFERS 3
typedef struct
{
	AudioStreamBasicDescription  dataFormat;
	AudioQueueRef                queue;
	AudioQueueBufferRef          buffers[NUM_BUFFERS];
	UInt32 num_samples_per_buffer;
	
	const NDIlib_v3* p_NDILib;
	NDIlib_recv_instance_t pNDI_recv;
	short *p_pcm_data;
	
	uint32_t capture_timeout;
	uint32_t pcm_data_size;
} PlayState;

// Fills an empty buffer with data and sends it to the speaker
void AudioOutputCallback(void * inUserData,
						 AudioQueueRef outAQ,
						 AudioQueueBufferRef outBuffer)
{
	PlayState* playState = (PlayState*)inUserData;
	const NDIlib_v3* p_NDILib = playState->p_NDILib;
	NDIlib_recv_instance_t pNDI_recv = playState->pNDI_recv;
	
	NDIlib_recv_queue_t audio_queued;
	audio_queued.audio_frames = 0;
	
	if (!playState->p_pcm_data)
	{
		memset(outBuffer->mAudioData, 0, outBuffer->mAudioDataBytesCapacity);
		outBuffer->mAudioDataByteSize = outBuffer->mAudioDataBytesCapacity;
		
		OSStatus status = AudioQueueEnqueueBuffer(playState->queue,
												  outBuffer,
												  0,
												  NULL);
		if (status != 0)
			printf("enqueuebuffer result %d \n", (int)status);
		
		p_NDILib->NDIlib_recv_get_queue(pNDI_recv, &audio_queued);
		for (int i = 2; i < audio_queued.audio_frames; i++)
		{
			NDIlib_audio_frame_v2_t audio_frame;
			NDIlib_frame_type_e type_captured = p_NDILib->NDIlib_recv_capture_v2(pNDI_recv, NULL, &audio_frame, NULL, 0);
			if (NDIlib_frame_type_audio == type_captured)
				p_NDILib->NDIlib_recv_free_audio_v2(pNDI_recv, &audio_frame);
			else
				break;
		}
	}
	else
	{
		const UInt32 num_copy_bytes = std::min<UInt32>(outBuffer->mAudioDataBytesCapacity, playState->pcm_data_size);
		::memcpy(outBuffer->mAudioData, playState->p_pcm_data, num_copy_bytes);
		outBuffer->mAudioDataByteSize = num_copy_bytes;
		
		OSStatus status = AudioQueueEnqueueBuffer(playState->queue,
												  outBuffer,
												  0,
												  NULL);
		if (status != 0)
			printf("enqueuebuffer result %d \n", (int)status);
		
		delete playState->p_pcm_data;
		playState->p_pcm_data = 0;
		playState->pcm_data_size = 0;
		
		p_NDILib->NDIlib_recv_get_queue(pNDI_recv, &audio_queued);
	}
	
	// Wait at maximum 1.5 times the duration of a buffer's worth of data
	static const uint32_t timeout_in_ms = (playState->num_samples_per_buffer * 1500) / (static_cast<uint32_t>(playState->dataFormat.mSampleRate));
	NDIlib_audio_frame_v2_t audio_frame;
	NDIlib_frame_type_e type_captured = p_NDILib->NDIlib_recv_capture_v2(pNDI_recv, NULL, &audio_frame, NULL, timeout_in_ms);
	if (NDIlib_frame_type_audio == type_captured)
	{
		printf("Audio data received (%d samples). Audio frames queued (%d frames) \n", audio_frame.no_samples, audio_queued.audio_frames);
		
		// Allocate enough space for 16bpp interleaved buffer
		NDIlib_audio_frame_interleaved_16s_t audio_frame_16bpp_interleaved = { 0 };
		audio_frame_16bpp_interleaved.reference_level = 0;	// Rather that 20dB of headroom, we will have none.
		audio_frame_16bpp_interleaved.p_data = playState->p_pcm_data = new short[audio_frame.no_samples*audio_frame.no_channels];
		playState->pcm_data_size = audio_frame.no_samples * audio_frame.no_channels * 2;
		
		// Convert it
		p_NDILib->NDIlib_util_audio_to_interleaved_16s_v2(&audio_frame, &audio_frame_16bpp_interleaved);
		
		p_NDILib->NDIlib_recv_free_audio_v2(pNDI_recv, &audio_frame);
	}
	else
		printf("*** Couldn't capture audio fast enough.  Might want to drop audio on next callback to prevent increased latency ***");
}


///////////////////////////////////////////////////////////////////////////////////////////////

void setupAudioFormat(AudioStreamBasicDescription *format, const NDIlib_audio_frame_v2_t &audio_frame)
{
	format->mSampleRate = audio_frame.sample_rate;
	format->mFormatID = kAudioFormatLinearPCM;
	format->mFramesPerPacket = 1;
	format->mChannelsPerFrame = audio_frame.no_channels;
	format->mBytesPerFrame = audio_frame.no_channels * 2;
	format->mBytesPerPacket = audio_frame.no_channels * 2;
	format->mBitsPerChannel = 16;
	format->mReserved = 0;
	format->mFormatFlags = //kLinearPCMFormatFlagIsBigEndian     |
	kLinearPCMFormatFlagIsSignedInteger |
	kLinearPCMFormatFlagIsPacked;
	
	printf("setup audio format : %d sample rate.  %d num channels \n", audio_frame.sample_rate, audio_frame.no_channels);
}

///////////////////////////////////////////////////////////////////////////////////////////////



int main(int argc, char* argv[])
{
	std::string ndi_path;
	
	// ToDo
	const char* p_NDI_runtime_folder = ::getenv("NDI_RUNTIME_DIR_V4");
	if (p_NDI_runtime_folder)
	{
		ndi_path = p_NDI_runtime_folder;
		ndi_path += "/libndi.dylib";
	}
	else
		ndi_path = "libndi.4.dylib"; // The standard versioning scheme on Linux based systems using sym links
	
	// Try to load the library
	void *hNDILib = ::dlopen(ndi_path.c_str(), RTLD_LOCAL | RTLD_LAZY);
	
	// The main NDI entry point for dynamic loading if we got the library
	const NDIlib_v3* (*NDIlib_v3_load)(void) = NULL;
	if (hNDILib)
		*((void**)&NDIlib_v3_load) = ::dlsym(hNDILib, "NDIlib_v3_load");
	
	if (!NDIlib_v3_load)
	{
		printf("Please re-install the NewTek NDI Runtimes to use this application.");
		return 0;
	}
	
	// Lets get all of the DLL entry points
	const NDIlib_v3* p_NDILib = NDIlib_v3_load();
	
	// We can now run as usual
	if (!p_NDILib->NDIlib_initialize())
	{	// Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
		// you can check this directly with a call to NDIlib_is_supported_CPU()
		printf("Cannot run NDI.");
		return 0;
	}
	
	// Catch interrupt so that we can shut down gracefully
	signal(SIGINT, sigint_handler);
	
	// We first need to look for a source on the network
	const NDIlib_find_create_t NDI_find_create_desc = { true, NULL };
	
	// Create a finder
	NDIlib_find_instance_t pNDI_find = p_NDILib->NDIlib_find_create_v2(&NDI_find_create_desc);
	if (!pNDI_find) return 0;
	
	// We wait until there is at least one source on the network
	uint32_t no_sources = 0;
	const NDIlib_source_t* p_sources = NULL;
	while (!exit_loop && !no_sources)
	{	// Wait until the sources on the nwtork have changed
		p_NDILib->NDIlib_find_wait_for_sources(pNDI_find, 1000);
		p_sources = p_NDILib->NDIlib_find_get_current_sources(pNDI_find, &no_sources);
	}
	
	// We need at least one source
	if (!p_sources) return 0;
	
	// ToDo
	/*
	NDIlib_source_t ndi_source = { 0 };
	ndi_source.p_ip_address = "";
	ndi_source.p_ndi_name = "NewTek (NewTek SDI)";
	*/
	
	// We now have at least one source, so we create a receiver to look at it.
	// We tell it that we prefer YCbCr video since it is more efficient for us. If the source has an alpha channel
	// it will still be provided in BGRA
	NDIlib_recv_create_v3_t NDI_recv_create_desc = { p_sources[0], NDIlib_recv_color_format_fastest, NDIlib_recv_bandwidth_audio_only, /* Allow fielded video */true, "Audio Play Example Receiver" };
	
	// Create the receiver
	NDIlib_recv_instance_t pNDI_recv = p_NDILib->NDIlib_recv_create_v3(&NDI_recv_create_desc);
	if (!pNDI_recv)
	{	p_NDILib->NDIlib_find_destroy(pNDI_find);
		return 0;
	}
	
	// Destroy the NDI finder. We needed to have access to the pointers to p_sources[0]
	p_NDILib->NDIlib_find_destroy(pNDI_find);
	
	// Instantiate our PlayState
	PlayState playState = { 0 };
	playState.p_NDILib = p_NDILib;
	playState.pNDI_recv = pNDI_recv;
	
	// Try for one minute to get audio
	const auto start = std::chrono::high_resolution_clock::now();
	while (!exit_loop && std::chrono::high_resolution_clock::now() - start < std::chrono::minutes(1))
	{
		// The descriptors
		NDIlib_audio_frame_v2_t audio_frame;
		NDIlib_frame_type_e type_captured = p_NDILib->NDIlib_recv_capture_v2(pNDI_recv, NULL, &audio_frame, NULL, 1000);
		if (NDIlib_frame_type_audio == type_captured)
		{
			setupAudioFormat(&playState.dataFormat, audio_frame);
			playState.num_samples_per_buffer = audio_frame.no_samples;
			p_NDILib->NDIlib_recv_free_audio_v2(pNDI_recv, &audio_frame);
			break;
		}
		else
			printf("Timed out receiving audio from NDI source \n");
	}
	
	const bool have_audio = (playState.num_samples_per_buffer != 0);
	if (have_audio)
	{
		// Allocate the audio queue and the buffers
		OSStatus status;
		status = AudioQueueNewOutput(&playState.dataFormat,
									 AudioOutputCallback,
									 &playState,
									 CFRunLoopGetCurrent(),
									 kCFRunLoopCommonModes,
									 0,
									 &playState.queue);
		
		if (status == 0)
		{
			// Allocate and initialize playback buffers
			for (int i = 0; i < NUM_BUFFERS; i++)
			{
				const UInt32 buffer_size = playState.num_samples_per_buffer * playState.dataFormat.mChannelsPerFrame * 2; // 2 == sizeof(short) == size of sample
				AudioQueueAllocateBuffer(playState.queue, buffer_size, &playState.buffers[i]);
				
				::memset(playState.buffers[i]->mAudioData, 0, buffer_size);
				playState.buffers[i]->mAudioDataByteSize = buffer_size;
				
				OSStatus status = AudioQueueEnqueueBuffer(playState.queue,
														  playState.buffers[i],
														  0,
														  NULL);
				assert(status == 0);
			}
			
			// Prime the playback buffers
			UInt32 num_frames_prepared = 0;
			status = AudioQueuePrime(playState.queue, playState.num_samples_per_buffer * NUM_BUFFERS, &num_frames_prepared);
			printf("Num frames primed is %d !!! \n", (int)num_frames_prepared);
			
			// Flush all the audio out of the receiver before beginning playback
			while (!exit_loop)
			{
				NDIlib_audio_frame_v2_t audio_frame;
				NDIlib_frame_type_e type_captured = p_NDILib->NDIlib_recv_capture_v2(pNDI_recv, NULL, &audio_frame, NULL, 0);
				if (NDIlib_frame_type_audio == type_captured)
					p_NDILib->NDIlib_recv_free_audio_v2(pNDI_recv, &audio_frame);
				else
					break;
			}
			
			// Start the audio queue playback
			status = AudioQueueStart(playState.queue, NULL);
			if (status == 0)
			{
				printf("Playing \n");
			}
			else
				printf("AudioQueueStart returned status %d \n", (int)status);
		}

		
		// Allow audio to playback for 30 seconds
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30.0, false);
		
		// Stop the audio queue callbacks
		AudioQueueStop(playState.queue, true);
	}
	
	// Destroy the receiver
	printf("Destroying the NDI receiver \n");
	p_NDILib->NDIlib_recv_destroy(pNDI_recv);
	printf("The NDI receiver has been destroyed \n");
	
	// Not required, but nice
	p_NDILib->NDIlib_destroy();
	
	if (have_audio)
	{
		for(int i = 0; i < NUM_BUFFERS; i++)
		{
			AudioQueueFreeBuffer(playState.queue, playState.buffers[i]);
		}
		
		AudioQueueDispose(playState.queue, true);
	}
	
	// Finished
	return 0;
}

