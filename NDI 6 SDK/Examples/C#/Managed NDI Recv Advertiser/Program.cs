using System;
using System.Runtime.InteropServices;
using NewTek;
using NewTek.NDI;

// This is an example of using the receiver advertiser methods directly
// as you would in C.

namespace Managed_NDI_Recv_Advertiser
{
    class Program
    {
        static void Main(string[] args)
        {
            // Not required, but "correct". (see the SDK documentation)
            if (!NDIlib.initialize())
            {
                // Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
                // you can check this directly with a call to NDIlib_is_supported_CPU()
                Console.WriteLine("Cannot run NDI");
                return;
            }

            // make a description of the receiver we want
            NDIlib.recv_create_v3_t recvDescription = new NDIlib.recv_create_v3_t()
            {
                // we want BGRA frames for this example
                color_format = NDIlib.recv_color_format_e.recv_color_format_BGRX_BGRA,

                // we want full quality - for small previews or limited bandwidth, choose lowest
                bandwidth = NDIlib.recv_bandwidth_e.recv_bandwidth_highest,

                // let NDIlib deinterlace for us if needed
                allow_video_fields = false,

                // The name of the NDI receiver to create. This is a NULL terminated UTF8 string and should be
                // the name of receive channel that you have. This is in many ways symmetric with the name of
                // senders, so this might be "Channel 1" on your system.
                p_ndi_recv_name = UTF.StringToUtf8("")
            };

            // We create an unconnected receiver that will be setup for advertising.
            IntPtr pNDI_recv = NDIlib.recv_create_v3(ref recvDescription);
            if (pNDI_recv == IntPtr.Zero)
                return;

            // free the memory we allocated with StringToUtf8
            Marshal.FreeHGlobal(recvDescription.p_ndi_recv_name);

            NDIlib.recv_advertiser_create_t recvAdvertiserDescription = new NDIlib.recv_advertiser_create_t()
            {
                // The URL address of the NDI Discovery Server to connect to. If NULL, then the default NDI discovery
                // server will be used. If there is no discovery server available, then the receiver advertiser will not
                // be able to be instantiated and the create function will return NULL. The format of this field is
                // expected to be the hostname or IP address, optionally followed by a colon and a port number. If the
                // port number is not specified, then port 5959 will be used. For example,
                //     127.0.0.1:5959
                //       or
                //     127.0.0.1
                //       or
                //     hostname:5959
                // This field can also specify multiple addresses separated by commas for redundancy support.
                p_url_address = UTF.StringToUtf8("127.0.0.1")
            };

            // Create an instance of the receiver advertiser
            IntPtr pNDI_recv_advertiser = NDIlib.recv_advertiser_create(ref recvAdvertiserDescription);

            // free the memory we allocated with StringToUtf8
            Marshal.FreeHGlobal(recvAdvertiserDescription.p_url_address);

            if (pNDI_recv_advertiser == IntPtr.Zero)
            {
                Console.WriteLine("The receiver advertiser failed to create. Please configure the connection to the NDI discovery server.\n");
                NDIlib.recv_destroy(pNDI_recv);
                NDIlib.destroy();
                return;
            }

            IntPtr p_input_name = UTF.StringToUtf8("Input");

            // free the memory we allocated with StringToUtf8
            Marshal.FreeHGlobal(p_input_name);

            // Register the receiver with the advertiser
            NDIlib.recv_advertiser_add_receiver(pNDI_recv_advertiser, pNDI_recv, true, true, p_input_name);

            // Run for five minutes.
            DateTime startTime = DateTime.Now;
            while (DateTime.Now - startTime < TimeSpan.FromMinutes(5)) 
			{ 
				// The descriptors
				NDIlib.video_frame_v2_t video_frame = new NDIlib.video_frame_v2_t();
				NDIlib.audio_frame_v2_t audio_frame = new NDIlib.audio_frame_v2_t();
                NDIlib.metadata_frame_t metadata_frame = new NDIlib.metadata_frame_t();

                switch (NDIlib.recv_capture_v2(pNDI_recv, ref video_frame, ref audio_frame, ref metadata_frame, 1000)) {
					// No data
					case NDIlib.frame_type_e.frame_type_none:
						Console.WriteLine("No data received.");
						break;

					// Video data
					case NDIlib.frame_type_e.frame_type_video:
						Console.WriteLine($"Video data received ({video_frame.xres}x{video_frame.yres}).");
						NDIlib.recv_free_video_v2(pNDI_recv, ref video_frame);
						break;

					// Audio data
					case NDIlib.frame_type_e.frame_type_audio:
						Console.WriteLine($"Audio data received ({audio_frame.no_samples} samples).");
						NDIlib.recv_free_audio_v2(pNDI_recv, ref audio_frame);
						break;

					// Metadata
					case NDIlib.frame_type_e.frame_type_metadata:
						Console.WriteLine($"Received metadata {metadata_frame.p_data}");
						NDIlib.recv_free_metadata(pNDI_recv, ref metadata_frame);
						break;

					// There is a status change on the receiver (e.g. new web interface).
					case NDIlib.frame_type_e.frame_type_status_change:
						Console.WriteLine("Receiver connection status changed.");
						break;

					case NDIlib.frame_type_e.frame_type_source_change:
					{
						IntPtr p_source_name = IntPtr.Zero;
						if (NDIlib.recv_get_source_name(pNDI_recv, p_source_name)) {
							// The name of the source could be NULL, which would mean the receiver is set to be
							// connected to nothing.
							if (p_source_name != IntPtr.Zero)
                                Console.WriteLine($"Source name changed: {p_source_name}");
							else
								Console.WriteLine("Not connected to a source");
						}

						// Whether the source name has changed or not, the pointer should be set to the name of the
						// current source and will have to be released.
						if (p_source_name != IntPtr.Zero)
							NDIlib.recv_free_string(pNDI_recv, p_source_name);
						break;
					}
				}
			}

            // Remove the receiver from the advertiser before destroying it.
            NDIlib.recv_advertiser_del_receiver(pNDI_recv_advertiser, pNDI_recv);

            // Destroy the receiver advertiser.
            NDIlib.recv_advertiser_destroy(pNDI_recv_advertiser);

            // Destroy the receiver.
            NDIlib.recv_destroy(pNDI_recv);

            // Clean up the initialization.
            NDIlib.destroy();
        }
    }
}
