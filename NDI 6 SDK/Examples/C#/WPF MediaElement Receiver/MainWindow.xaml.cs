using System;
using System.Windows;

// This example takes advantage of the NDI DirectShow filter
// included with the SDK.

// Once installed, the standard WPF MediaElement and many other
// DirectShow applications will be able to receive NDI streams.

// Make sure that you have registered the NDISourceFilter dlls
// in order to make Windows aware of the ndi:// stream format.
// regsvr32 Path/to/files/Filters.NdiSourceFilter.x64.dll
// and
// regsvr32 Path/to/files/Filters.NdiSourceFilter.x86.dll

// The dll is self contained and needs no other supporting files.

namespace WPF_MediaElement_Receiver
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();

            // We are doing this the hard way, building the Uri manually.
            // The NewTek.NDI.Source objects returned by NewTek.Ndi.Finder
            // have a Uri property that the MediaElement could have bound to.

            // change this to your own computer name.
            String computerName = "ComputerName";

            // Change this to the source you want from that computer.
            // Note that we don't include the parenthesis that you see in many NDI applicaitons.
            // You need to url encode the source name in case it has illegal characters like spaces.
            String sourceName = System.Net.WebUtility.UrlEncode("Source Name");

            // build up the string for the Uri
            String sourceUriString = String.Format("ndi://{0}/{1}", computerName, sourceName);

            // If you want options passed to the uri, add them on now.
            // Uncomment the next line for low quality/bandwidth and no audio
            // All options are listed in the documentation.
            // videoUriString += "?low_quality=true";

            // now create a Uri object and assign it to the MediaElement
            Uri sourceUri;
            if (Uri.TryCreate(sourceUriString, UriKind.Absolute, out sourceUri))
            {
                VideoMediaElement.Source = sourceUri;
            }
        }
    }
}
