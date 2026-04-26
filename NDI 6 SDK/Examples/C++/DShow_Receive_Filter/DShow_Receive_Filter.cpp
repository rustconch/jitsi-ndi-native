#include <windows.h>
#include <atlbase.h>
#include <dshow.h>
#pragma comment (lib, "strmiids.lib")

// Make sure that you have registered the NDISourceFilter dlls
// in order to make Windows aware of the ndi:// stream format.
// regsvr32 Path/to/files/Filters.NdiSourceFilter.x64.dll
// and
// regsvr32 Path/to/files/Filters.NdiSourceFilter.x86.dll

// The dll is self contained and needs no other supporting files.

// NDI streams often change resolution and framerate mid-stream.
// Downstream video filters used in the graph must support Dynamic Format Changes as documented here:
// https://msdn.microsoft.com/en-us/library/windows/desktop/dd388731%28v=vs.85%29.aspx?f=255&MSPPError=-2147217396

// If the filter can not perform a dynamic format change, it will detect this
// and refuse to connect or end the stream prematurely in the event of failure to change formats.

// Debugging information is printed to debug out on most errors and on stream format changes.
// This can be viewed with an attached debugger or Microsoft/Sysinternals DebugView.

// the basic URL format is:
// ndi://SystemName/SourceName

// You must identify systems by name, not IP address.
// Make sure to properly escape your URLs in the standard way.
// Spaces should be replaced with '+' or '%20', etc.

// If you see this name in Network Video Monitor or TriCaster:
// "MyTC (Out 1)"
// then the URL would be:
// ndi://MyTC/Out+1
// Note that the parenthesis are not used and the space has been
// escaped with a plus sign.

// Below are several example with combinations of optional modifiers.

// Defaults - UYVY (no alpha channel), high quality, video and audio
// ndi://TriCaster/Out+1

// This is the same as
// ndi://TriCaster/Out+1?video=true&audio=true

// Audio only
// ndi://TriCaster/Out+1?video=false

// Combine options with &
// low quality/bandwidth, rgb to support alpha channel and no audio
// ndi://Laptop/VLC?low_quality=true&rgb=true&audio=false

// Force the aspect ratio to be 4/3
// Useful with some DShow renderers that are unable to change aspect while the graph is running.
// ndi://MyComputer/Router+Example?force_aspect=1.33333

// You can alternatively instantiate the filter by GUID and then call Load with the URL.
// DEFINE_GUID(CLSID_NdiSourceFilter, 0x90f86efc, 0x87cf, 0x4097,
//				0x9f, 0xce, 0xc, 0x11, 0xd5, 0x73, 0xff, 0x8f);

int _tmain(int argc, _TCHAR* argv[])
{
	HRESULT hr = CoInitialize(NULL);
	if (SUCCEEDED(hr)) {
		long evCode;
		CComPtr<IGraphBuilder>	pGraph = NULL;
		CComPtr<IMediaControl>	pControl = NULL;
		CComPtr<IMediaEvent>	pEvent = NULL;
		CComPtr<IBaseFilter>	pRenderer = NULL;

		if (SUCCEEDED(hr))
			hr = CoCreateInstance(CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, (void**)&pGraph);

		if (SUCCEEDED(hr))
			hr = pGraph->QueryInterface(IID_IMediaControl, (void**)&pControl);

		if (SUCCEEDED(hr))
			hr = pGraph->QueryInterface(IID_IMediaEvent, (void**)&pEvent);

		// Optional:
		// By default RenderFile uses the outdated VMR7 for display.
		// We will instead add an instance of the slightly more modern VMR9 filter to the graph before calling RenderFile.
		// The default audio renderer will be added automatically.
		if (SUCCEEDED(hr))
			hr = CoCreateInstance(CLSID_VideoMixingRenderer9, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pRenderer));

		if (SUCCEEDED(hr))
			hr = pGraph->AddFilter(pRenderer, L"VMR9");

		// You will need to insert your own machine name and source name below.
		if (SUCCEEDED(hr))
			hr = pGraph->RenderFile(L"ndi://MachineName/SourceName", NULL);

		if (SUCCEEDED(hr))
			hr = pControl->Run();

		// You wouldn't normally use INFINITE in a real application
		if (SUCCEEDED(hr))
			pEvent->WaitForCompletion(INFINITE, &evCode);

		CoUninitialize();
	}

	return FAILED(hr);
}
