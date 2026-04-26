//
// MainPage.xaml.cpp
// Implementation of the MainPage class.
//

// NOTE : You will only receive video for x64 builds

#include "pch.h"
#include "MainPage.xaml.h"
#include <wrl.h>
#include <MemoryBuffer.h>
#include <Robuffer.h>
#include <windows.h>

using namespace NDIlib_UWP_GrabStill;

using namespace Platform;
using namespace Windows::Foundation;
using namespace Windows::Foundation::Collections;
using namespace Windows::UI::Xaml;
using namespace Windows::UI::Xaml::Controls;
using namespace Windows::UI::Xaml::Controls::Primitives;
using namespace Windows::UI::Xaml::Data;
using namespace Windows::UI::Xaml::Input;
using namespace Windows::UI::Xaml::Media;
using namespace Windows::UI::Xaml::Navigation;
using namespace Windows::UI::Xaml::Media::Imaging;
using namespace Windows::Graphics::Imaging;

using namespace Windows::Storage::Streams;

// The Blank Page item template is documented at https://go.microsoft.com/fwlink/?LinkId=402352&clcid=0x409

MainPage::MainPage()
{
	// Create our finder and observable collection of sources
	m_p_finder = ::NDIlib_find_create_v2();
	m_ndi_source_names = ref new Vector<String^>();

	// We are going to demonstrate NDI routing as well with this example
	NDIlib_routing_create_t routing_create_desc;
	routing_create_desc.p_ndi_name = "UWPRouter";
	m_p_router = ::NDIlib_routing_create(&routing_create_desc);

	InitializeComponent();

	// Try to do the initial population of the sources list view
	DoUpdateNDISources();
}

MainPage::~MainPage()
{
	// Clean up the router
	if (m_p_router)
	{
		::NDIlib_routing_destroy(m_p_router);
		m_p_router = nullptr;
	}

	// Clean up our finder
	if (m_p_finder)
	{
		::NDIlib_find_destroy(m_p_finder);
		m_p_finder = nullptr;
	}
}

void MainPage::DoUpdateNDISources(void)
{
	m_ndi_source_names->Clear();

	uint32_t num_sources = 0;
	const NDIlib_source_t *p_sources = ::NDIlib_find_get_current_sources(m_p_finder, &num_sources);

	for (uint32_t i = 0; i < num_sources; i++)
	{
		// Do the string conversion
		std::wstring ndi_name;
		const int requiredSize = ::MultiByteToWideChar(CP_ACP, 0, p_sources[i].p_ndi_name, -1, 0, 0);
		if (requiredSize > 0)
		{
			ndi_name.resize(requiredSize - 1);
			::MultiByteToWideChar(CP_ACP, 0, p_sources[i].p_ndi_name, -1, &ndi_name[0], requiredSize - 1);
		}

		// Add it to the list view
		m_ndi_source_names->Append(ref new String(ndi_name.c_str()));
	}
}

void MainPage::DoRefreshStill(void)
{
	if (!m_ndi_source_name)
		return;

	// Convert to the proper string type
	std::string sender_name;
	const int requiredSize = ::WideCharToMultiByte(CP_ACP, 0, m_ndi_source_name->Data(), -1, 0, 0, 0, 0);
	if (requiredSize > 0)
	{
		sender_name.resize(requiredSize - 1);
		::WideCharToMultiByte(CP_ACP, 0, m_ndi_source_name->Data(), -1, &sender_name[0], requiredSize - 1, 0, 0);
	}

	if (m_p_router)
	{
		// Route to the newly selected source
		NDIlib_source_t route_to;
		route_to.p_ndi_name = sender_name.c_str();
		NDIlib_routing_change(m_p_router, &route_to);
	}

	// Connect to this sender and capture one preview video frame
	NDIlib_recv_create_v3_t recv_create;
	recv_create.source_to_connect_to.p_ndi_name = sender_name.c_str();
	recv_create.color_format = NDIlib_recv_color_format_BGRX_BGRA;
	recv_create.bandwidth = NDIlib_recv_bandwidth_lowest;

	// Create the receiver
	NDIlib_recv_instance_t p_recv = ::NDIlib_recv_create_v3(&recv_create);

	// Try to capture a video frame in 2 seconds
	NDIlib_video_frame_v2_t video_data;
	for (int i = 0; i < 8; i++)
	{
		if (::NDIlib_recv_capture_v2(p_recv, &video_data, NULL, NULL, 250) == NDIlib_frame_type_video)
		{
			// Create a writable bitmap
			WriteableBitmap^ p_bmp = ref new WriteableBitmap(video_data.xres, video_data.yres);
			IBuffer^ p_buf = p_bmp->PixelBuffer;
			Microsoft::WRL::ComPtr<IInspectable> p_inspectable = reinterpret_cast<IInspectable*>(p_buf);

			// Get access to the pixel buffer
			Microsoft::WRL::ComPtr<IBufferByteAccess> p_buf_bytes;
			HRESULT hr = p_inspectable.As(&p_buf_bytes);
			byte* p_dst(nullptr);
			hr = p_buf_bytes->Buffer(&p_dst);
			const int dest_stride = video_data.xres * 4;

			// Copy each scan line
			byte* p_src = video_data.p_data;
			for (int y = 0; y < video_data.yres; y++)
			{
				::memcpy(p_dst, p_src, dest_stride);
				p_src += video_data.line_stride_in_bytes;
				p_dst += dest_stride;
			}

			// Convert it to something that can be used as the Source of a XAML Image
			SoftwareBitmap^ p_outputBitmap = SoftwareBitmap::CreateCopyFromBuffer(p_bmp->PixelBuffer, BitmapPixelFormat::Bgra8, p_bmp->PixelWidth, p_bmp->PixelHeight, BitmapAlphaMode::Premultiplied);
			SoftwareBitmapSource^ p_bmp_src = ref new SoftwareBitmapSource();
			p_bmp_src->SetBitmapAsync(p_outputBitmap);

			// Update our XAML image
			this->CapturedPreviewImage->Source = p_bmp_src;
			this->CapturedPreviewImage->Width = video_data.xres;
			this->CapturedPreviewImage->Height = video_data.yres;

			// Free the captured video frame
			::NDIlib_recv_free_video_v2(p_recv, &video_data);
			break;
		}
	}

	// Delete the receiver
	::NDIlib_recv_destroy(p_recv);
}

void MainPage::SourcesListView_SelectionChanged(Platform::Object^ sender, Windows::UI::Xaml::Controls::SelectionChangedEventArgs^ e)
{
	m_ndi_source_name = ((ListView^)sender)->SelectedItem->ToString();
	DoRefreshStill();
}

void MainPage::Refresh_Still_Button_Click(Platform::Object^ sender, Windows::UI::Xaml::RoutedEventArgs^ e)
{
	DoRefreshStill();
}

void MainPage::Find_Sources_Button_Click(Platform::Object^ sender, Windows::UI::Xaml::RoutedEventArgs^ e)
{
	DoUpdateNDISources();
}
