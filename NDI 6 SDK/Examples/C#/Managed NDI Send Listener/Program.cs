using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using NewTek;
using NewTek.NDI;

namespace Managed_NDI_Send_Listener
{
    class Program
    {
        private static void Main()
        {
            // Not required, but "correct". (see the SDK documentation)
            if (!NDIlib.initialize())
            {
                // Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
                // you can check this directly with a call to NDIlib_is_supported_CPU()
                Console.WriteLine("Cannot run NDI");
                return;
            }
            
            // how we want our find to operate
            NDIlib.NDIlib_send_listener_create_t findDesc = new NDIlib.NDIlib_send_listener_create_t
            {
                // optional IntPtr to a UTF-8 string. See above.
                p_url_address = UTF.StringToUtf8("127.0.0.1")
            };

            // create our sender listener instance
            IntPtr sendListenerInstancePtr = NDIlib.SenderListenerCreate(ref findDesc);
            
            // did it succeed?
            Debug.Assert(sendListenerInstancePtr != IntPtr.Zero, "Failed to create NDI Sender Listener instance.");

            // Make Sure you have the NDI Discovery Server running in the URL you used above!
            // Run for one minute
            DateTime startTime = DateTime.Now;
            while (DateTime.Now - startTime < TimeSpan.FromMinutes(1.0))
            {
                // Wait up till 5 seconds to check for new Senders to be added or removed
                if (!NDIlib.SenderListenerWaitForSources(sendListenerInstancePtr, 5000))
                {
                    // No new senders added !
                    Console.WriteLine("No change to the senders found.");
                }
                else
                {
                    // Get the updated list of senders
                    uint numSenders = 0;
                    IntPtr allSenders = NDIlib.SenderListenerGetCurrentSources(sendListenerInstancePtr, ref numSenders);

                    // Display all the Senders.
                    Console.WriteLine("Network Senders with Discovery Server control enabled ({0} found).", numSenders);

                    // if Senders == 0, then there was no change, keep your list
                    if (numSenders <= 0)
                    {
                        continue;
                    }

                    // the size of a sender_t, for pointer offsets
                    int senderSizeInBytes = Marshal.SizeOf(typeof(NDIlib.sender_t));

                    // convert each unmanaged ptr into a managed sender_t
                    for (int i = 0; i < numSenders; i++)
                    {
                        // source ptr + (index * size of a source)
                        IntPtr p = IntPtr.Add(allSenders, (i * senderSizeInBytes));

                        // marshal it to a managed source and assign to our list
                        NDIlib.sender_t src = (NDIlib.sender_t)Marshal.PtrToStructure(p, typeof(NDIlib.sender_t));

                        // .Net doesn't handle marshaling UTF-8 strings properly
                        string name = UTF.Utf8ToString(src.p_name);

                        Console.WriteLine("{0} {1}", i, name);
                    }
                }
            }
            
            Marshal.FreeHGlobal(findDesc.p_url_address);
            
            // Destroy the NDI find instance
            NDIlib.SenderListenerDestroy(sendListenerInstancePtr);

            // Not required, but "correct". (see the SDK documentation)
            NDIlib.destroy();
        }
    }
}