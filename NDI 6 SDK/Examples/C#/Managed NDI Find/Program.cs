using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using NewTek;
using NewTek.NDI;

// This is an example of using the find methods directly
// as you would in C.
//
// For most use cases, the NewTek.NDI.Finder class will
// handle everything for you in a more .Net friendly way.
// Examples of this can be found in the Managed NDI Recv
// and Managed NDI Router examples.

namespace Managed_NDI_Find
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

            // This will be IntPtr.Zero 99.999% of the time.
            // Could be one "MyGroup" or multiples "public,My Group,broadcast 42" etc.
            // Create a UTF-8 buffer from our string
            // Must use Marshal.FreeHGlobal() after use!
            // IntPtr groupsPtr = NDI.Common.StringToUtf8("public");
            IntPtr groupsPtr = IntPtr.Zero;

            // This is also optional.
            // The list of additional IP addresses that exist that we should query for 
            // sources on. For instance, if you want to find the sources on a remote machine
            // that is not on your local sub-net then you can put a comma seperated list of 
            // those IP addresses here and those sources will be available locally even though
            // they are not mDNS discoverable. An example might be "12.0.0.8,13.0.12.8".
            // When none is specified (IntPtr.Zero) the registry is used.
            // Create a UTF-8 buffer from our string
            // Must use Marshal.FreeHGlobal() after use!
            // IntPtr extraIpsPtr = NDI.Common.StringToUtf8("12.0.0.8,13.0.12.8")
            IntPtr extraIpsPtr = IntPtr.Zero;

            // how we want our find to operate
            NDIlib.find_create_t findDesc = new NDIlib.find_create_t()
            {
                // optional IntPtr to a UTF-8 string. See above.
                p_groups = groupsPtr,

                // also the ones on this computer - useful for debugging
                show_local_sources = true,

                // optional IntPtr to a UTF-8 string. See above.
                p_extra_ips = extraIpsPtr

            };

            // create our find instance
            IntPtr _findInstancePtr = NDIlib.find_create_v2(ref findDesc);

            // free our UTF-8 buffer if we created one
            if (groupsPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(groupsPtr);
            }

            if (extraIpsPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(extraIpsPtr);
            }

            // did it succeed?
            System.Diagnostics.Debug.Assert(_findInstancePtr != IntPtr.Zero, "Failed to create NDI find instance.");


            // Run for one minute
            DateTime startTime = DateTime.Now;
            while (DateTime.Now - startTime < TimeSpan.FromMinutes(1.0))
            {
                // Wait up till 5 seconds to check for new sources to be added or removed
                if (!NDIlib.find_wait_for_sources(_findInstancePtr, 5000))
                {
                    // No new sources added !
                    Console.WriteLine("No change to the sources found.");
                }
                else
                {
                    // Get the updated list of sources
                    uint numSources = 0;
                    IntPtr p_sources = NDIlib.find_get_current_sources(_findInstancePtr, ref numSources);

                    // Display all the sources.
                    Console.WriteLine("Network sources ({0} found).", numSources);

                    // if sources == 0, then there was no change, keep your list
                    if (numSources > 0)
                    {
                        // the size of an NDIlib_source_t, for pointer offsets
                        int SourceSizeInBytes = Marshal.SizeOf(typeof(NDIlib.source_t));

                        // convert each unmanaged ptr into a managed NDIlib_source_t
                        for (int i = 0; i < numSources; i++)
                        {
                            // source ptr + (index * size of a source)
                            IntPtr p = IntPtr.Add(p_sources, (i * SourceSizeInBytes));

                            // marshal it to a managed source and assign to our list
                            NDIlib.source_t src = (NDIlib.source_t)Marshal.PtrToStructure(p, typeof(NDIlib.source_t));

                            // .Net doesn't handle marshaling UTF-8 strings properly
                            String name = UTF.Utf8ToString(src.p_ndi_name);

                            Console.WriteLine("{0} {1}", i, name);
                        }
                    }
                }
            }

            // Destroy the NDI find instance
            NDIlib.find_destroy(_findInstancePtr);

            // Not required, but "correct". (see the SDK documentation)
            NDIlib.destroy();

        }
    }
}
