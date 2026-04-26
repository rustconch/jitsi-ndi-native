//
// MainPage.xaml.h
// Declaration of the MainPage class.
//

// NOTE : You will only receive video for x64 builds

#pragma once

using namespace Platform;
using namespace Platform::Collections;
using namespace Windows::Foundation::Collections;

#include "MainPage.g.h"
#include "Processing.NDI.Lib.h"

namespace NDIlib_UWP_GrabStill
{
	/// <summary>
	/// An empty page that can be used on its own or navigated to within a Frame.
	/// </summary>
	[Windows::UI::Xaml::Data::Bindable]
	public ref class MainPage sealed
	{
	public:
		MainPage();

		void DoUpdateNDISources(void);
		void DoRefreshStill(void);

		property Windows::UI::Xaml::Interop::IBindableVector^ NDI_Source_Names
		{
			Windows::UI::Xaml::Interop::IBindableVector^ get()
			{
				return m_ndi_source_names;
			}
		}

	private:

		~MainPage();

		void SourcesListView_SelectionChanged(Platform::Object^ sender, Windows::UI::Xaml::Controls::SelectionChangedEventArgs^ e);
		void Refresh_Still_Button_Click(Platform::Object^ sender, Windows::UI::Xaml::RoutedEventArgs^ e);
		void Find_Sources_Button_Click(Platform::Object^ sender, Windows::UI::Xaml::RoutedEventArgs^ e);

	private:

		Vector<String^> ^m_ndi_source_names;
		String^ m_ndi_source_name;
		NDIlib_find_instance_t m_p_finder;
		NDIlib_routing_instance_t m_p_router;
	};
}
