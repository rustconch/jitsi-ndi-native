using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using NewTek;
using NewTek.NDI;

// This is an example of using the receiver listener methods directly
// as you would in C.

namespace Managed_NDI_Recv_Listener
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

            // The URL address of the NDI Discovery Server to connect to
            // Create a UTF-8 buffer from our string
            // Must use Marshal.FreeHGlobal() after use!
            // IntPtr p_url_address = NDI.Common.StringToUtf8("127.0.0.1");
            IntPtr urlPtr = IntPtr.Zero;

            // how we want our find to operate
            NDIlib.recv_listener_create_t findDesc = new NDIlib.recv_listener_create_t()
            {
                // optional IntPtr to a UTF-8 string. See above.
                p_url_address = urlPtr,
            };

            // create our receiver listener instance
            IntPtr recvListenerInstancePtr = NDIlib.recv_listener_create(ref findDesc);

            // free our UTF-8 buffer if we created one
            if (urlPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(urlPtr);
            }
            
            // did it succeed?
            Debug.Assert(recvListenerInstancePtr != IntPtr.Zero, "Failed to create NDI Receiver Listener instance.");

            // Make Sure you have the NDI Discovery Server running in the URL you used above!
            // Run for one minute
            DateTime startTime = DateTime.Now;
            while (DateTime.Now - startTime < TimeSpan.FromMinutes(1.0))
            {
                // Wait up till 5 seconds to check for new receivers to be added or removed
                if (!NDIlib.recv_listener_wait_for_receivers(recvListenerInstancePtr, 5000))
                {
                    // No new receivers added !
                    Console.WriteLine("No change to the receivers found.");
                }
                else
                {
                    // Get the updated list of receivers
                    uint numReceivers = 0;
                    IntPtr p_receivers = NDIlib.recv_listener_get_receivers(recvListenerInstancePtr, ref numReceivers);

                    // Display all the receivers.
                    Console.WriteLine("Network Receivers with Discovery Server control enabled ({0} found).", numReceivers);

                    // if receivers == 0, then there was no change, keep your list
                    if (numReceivers > 0)
                    {
                        // the size of an NDIlib_receiver_t, for pointer offsets
                        int receiverSizeInBytes = Marshal.SizeOf(typeof(NDIlib.receiver_t));

                        // convert each unmanaged ptr into a managed NDIlib_receiver_t
                        for (int i = 0; i < numReceivers; i++)
                        {
                            // source ptr + (index * size of a source)
                            IntPtr p = IntPtr.Add(p_receivers, (i * receiverSizeInBytes));

                            // marshal it to a managed source and assign to our list
                            NDIlib.receiver_t src = (NDIlib.receiver_t)Marshal.PtrToStructure(p, typeof(NDIlib.receiver_t));

                            // .Net doesn't handle marshaling UTF-8 strings properly
                            string name = UTF.Utf8ToString(src.p_name);

                            Console.WriteLine("{0} {1}", i, name);
                        }
                    }
                }
            }

            // Destroy the NDI find instance
            NDIlib.recv_listener_destroy(recvListenerInstancePtr);

            // Not required, but "correct". (see the SDK documentation)
            NDIlib.destroy();
        }
    }
}
