Imports NAudio.Wave
Imports System.Collections.Generic
Imports System.Collections.ObjectModel
Imports System.Runtime.InteropServices
Imports System.Threading
Imports System.Windows
Imports System.Windows.Controls
Imports System.Windows.Media
Imports System.Windows.Media.Imaging
Imports NewTek
Imports NewTek.NDI

Partial Public Class MainWindow
    Inherits Window
    Public Property VideoBitmap() As WriteableBitmap
        Get
            Return m_VideoBitmap
        End Get
        Private Set
            m_VideoBitmap = Value
        End Set
    End Property
    Private m_VideoBitmap As WriteableBitmap

    Public Property SourceNames() As ObservableCollection(Of [String])
        Get
            Return DirectCast(GetValue(SourceNamesProperty), ObservableCollection(Of [String]))
        End Get
        Set
            SetValue(SourceNamesProperty, Value)
        End Set
    End Property
    Public Shared ReadOnly SourceNamesProperty As DependencyProperty = DependencyProperty.Register("SourceNames", GetType(ObservableCollection(Of [String])), GetType(MainWindow), New PropertyMetadata(New ObservableCollection(Of [String])()))


    Public Sub New()
        InitializeComponent()

        ' Not required, but "correct". (see the SDK documentation)
        If Not NDIlib.initialize() Then
            ' Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
            ' you can check this directly with a call to NDIlib_is_supported_CPU()
            MessageBox.Show("Cannot run NDI")
            Close()
        End If

        InitFind()
    End Sub

#Region "UserInterface"

    Private Sub Window_Closing(sender As Object, e As System.ComponentModel.CancelEventArgs)
        ' we must free our unmanaged finder instance
        NDIlib.find_destroy(_findInstancePtr)

        ' Not required, but "correct". (see the SDK documentation)
        NDIlib.destroy()

        ' Stop the audio device if needed
        If _wasapiOut IsNot Nothing Then
            _wasapiOut.[Stop]()
        End If
    End Sub

    Private Sub OnUpdateButtonClick(sender As Object, e As RoutedEventArgs)
        UpdateFindList()
    End Sub

    Private Sub OnSelectionChanged(sender As Object, e As SelectionChangedEventArgs)
        Dim selectedName As [String] = DirectCast(SourcesListBox.SelectedItem, [String])

        ' To avoid disconnection during list refresh.
        ' This should be smarter in a real application.
        If [String].IsNullOrEmpty(selectedName) Then
            Return
        End If

        Connect(selectedName)
    End Sub

#End Region


#Region "NdiFind"

    Private Sub InitFind()
        ' This will be IntPtr.Zero 99.999% of the time.
        ' Could be one "MyGroup" or multiples "public,My Group,broadcast 42" etc.
        ' Create a UTF-8 buffer from our string
        ' Must use Marshal.FreeHGlobal() after use!
        ' IntPtr groupsPtr = NDI.Common.StringToUtf8("public");
        Dim groupsPtr As IntPtr = IntPtr.Zero

        ' This is also optional.
        ' The list of additional IP addresses that exist that we should query for 
        ' sources on. For instance, if you want to find the sources on a remote machine
        ' that is not on your local sub-net then you can put a comma seperated list of 
        ' those IP addresses here and those sources will be available locally even though
        ' they are not mDNS discoverable. An example might be "12.0.0.8,13.0.12.8".
        ' When none is specified (IntPtr.Zero) the registry is used.
        ' Create a UTF-8 buffer from our string
        ' Must use Marshal.FreeHGlobal() after use!
        ' IntPtr extraIpsPtr = NDI.Common.StringToUtf8("12.0.0.8,13.0.12.8")
        Dim extraIpsPtr As IntPtr = IntPtr.Zero

        ' how we want our find to operate
        ' optional IntPtr to a UTF-8 string. See above.

        ' also the ones on this computer - useful for debugging

        ' optional IntPtr to a UTF-8 string. See above.

        Dim findDesc As New NDIlib.find_create_t() With {
            .p_groups = groupsPtr,
            .show_local_sources = True,
            .p_extra_ips = extraIpsPtr
        }

        ' create our find instance
        _findInstancePtr = NDIlib.find_create_v2(findDesc)

        ' free our UTF-8 buffer if we created one
        If groupsPtr <> IntPtr.Zero Then
            Marshal.FreeHGlobal(groupsPtr)
        End If

        If extraIpsPtr <> IntPtr.Zero Then
            Marshal.FreeHGlobal(extraIpsPtr)
        End If

        ' did it succeed?
        System.Diagnostics.Debug.Assert(_findInstancePtr <> IntPtr.Zero, "Failed to create NDI find instance.")

        ' attach it to our listbox
        SourcesListBox.ItemsSource = SourceNames

        ' update the list
        UpdateFindList()
    End Sub

    Private Sub UpdateFindList()
        Dim NumSources As UInteger = 0

        ' ask for an update
        ' timeout == 0, always return the full list
        ' timeout > 0, wait timeout ms, then return 0 for no change or the total number of sources found
        Dim SourcesPtr As IntPtr = NDIlib.find_get_current_sources(_findInstancePtr, NumSources)

        ' if sources == 0, then there was no change, keep your list
        If NumSources > 0 Then
            ' clear our list and dictionary
            SourceNames.Clear()
            _sources.Clear()

            ' the size of an NDIlib_source_t, for pointer offsets
            Dim SourceSizeInBytes As Integer = Marshal.SizeOf(GetType(NDIlib.source_t))

            ' convert each unmanaged ptr into a managed NDIlib_source_t
            For i As Integer = 0 To CInt(NumSources - 1)
                ' source ptr + (index * size of a source)
                Dim p As IntPtr = IntPtr.Add(SourcesPtr, (i * SourceSizeInBytes))

                ' marshal it to a managed source and assign to our list
                Dim src As NDIlib.source_t = CType(Marshal.PtrToStructure(p, GetType(NDIlib.source_t)), NDIlib.source_t)

                ' .Net doesn't handle marshaling UTF-8 strings properly
                Dim name As [String] = UTF.Utf8ToString(src.p_ndi_name)

                ' add it to the list and dictionary
                If Not _sources.ContainsKey(name) AndAlso Not SourceNames.Contains(name) Then
                    _sources.Add(name, src)
                    SourceNames.Add(name)
                End If
            Next
        End If
    End Sub

#End Region


#Region "NdiReceive"

    ' connect to an NDI source in our Dictionary by name
    Private Sub Connect(sourceName As [String])
        ' just in case we're already connected
        Disconnect()

        ' we need valid information to connect
        If [String].IsNullOrEmpty(sourceName) OrElse Not _sources.ContainsKey(sourceName) Then
            Return
        End If

        ' find our new source
        Dim source As NDIlib.source_t = _sources(sourceName)

        ' A name we call our receiver. Sent to NDI. REQUIRED.
        Dim recvNamePtr As IntPtr = UTF.StringToUtf8("VB.Net Receiver")

        ' make a description of the receiver we want
        ' the source we selected

        ' we want BGRA frames for this example

        ' we want full quality - for small previews or limited bandwidth, choose lowest
        Dim recvDescription As New NDIlib.recv_create_v3_t() With {
            .source_to_connect_to = source,
            .color_format = NDIlib.recv_color_format_e.recv_color_format_BGRX_BGRA,
            .bandwidth = NDIlib.recv_bandwidth_e.recv_bandwidth_highest,
            .allow_video_fields = False,
            .p_ndi_recv_name = recvNamePtr
        }

        ' create a new instance connected to this source
        _recvInstancePtr = NDIlib.recv_create_v3(recvDescription)

        ' free the string we allocated
        Marshal.FreeHGlobal(recvNamePtr)

        ' did it work?
        System.Diagnostics.Debug.Assert(_recvInstancePtr <> IntPtr.Zero, "Failed to create NDI receive instance.")

        If _recvInstancePtr <> IntPtr.Zero Then
            ' We are now going to mark this source as being on program output for tally purposes (but not on preview)
            SetTallyIndicators(True, False)

            ' start up a thread to receive on
            _receiveThread = New Thread(AddressOf ReceiveThreadProc) With {
                .IsBackground = True,
                .Name = "NdiExampleReceiveThread"
            }
            _receiveThread.Start()
        End If
    End Sub

    Private Sub Disconnect()
        ' in case we're connected, reset the tally indicators
        SetTallyIndicators(False, False)

        ' check for a running thread
        If _receiveThread IsNot Nothing Then
            ' tell it to exit
            _exitThread = True

            ' wait for it to exit
            While _receiveThread.IsAlive
                Thread.Sleep(100)
            End While
        End If

        ' reset thread defaults
        _receiveThread = Nothing
        _exitThread = False

        ' Destroy the receiver
        NDIlib.recv_destroy(_recvInstancePtr)

        ' set it to a safe value
        _recvInstancePtr = IntPtr.Zero
    End Sub

    Private Sub SetTallyIndicators(onProgram As Boolean, onPreview As Boolean)
        ' we need to have a receive instance
        If _recvInstancePtr <> IntPtr.Zero Then
            ' set up a state descriptor
            Dim tallyState As New NDIlib.tally_t() With {
                .on_program = onProgram,
                .on_preview = onPreview
            }

            ' set it on the receiver instance
            NDIlib.recv_set_tally(_recvInstancePtr, tallyState)
        End If
    End Sub

    ' the receive thread runs though this loop until told to exit
    Private Sub ReceiveThreadProc()
        While Not _exitThread AndAlso _recvInstancePtr <> IntPtr.Zero
            ' The descriptors
            Dim videoFrame As New NDIlib.video_frame_v2_t()
            Dim audioFrame As New NDIlib.audio_frame_v2_t()
            Dim metadataFrame As New NDIlib.metadata_frame_t()

            Select Case NDIlib.recv_capture_v2(_recvInstancePtr, videoFrame, audioFrame, metadataFrame, 1000)
                ' No data
                Case NDIlib.frame_type_e.frame_type_none
                    ' No data received
                    Exit Select

                    ' Video data
                Case NDIlib.frame_type_e.frame_type_video

                    ' this can occasionally happen when changing sources
                    If videoFrame.p_data = IntPtr.Zero Then
                        ' alreays free received frames
                        NDIlib.recv_free_video_v2(_recvInstancePtr, videoFrame)

                        Exit Select
                    End If

                    ' get all our info so that we can free the frame
                    Dim yres As Integer = CInt(videoFrame.yres)
                    Dim xres As Integer = CInt(videoFrame.xres)

                    ' quick and dirty aspect ratio correction for non-square pixels - SD 4:3, 16:9, etc.
                    Dim dpiX As Double = 96.0 * (videoFrame.picture_aspect_ratio / (CDbl(xres) / CDbl(yres)))

                    Dim stride As Integer = CInt(videoFrame.line_stride_in_bytes)
                    Dim bufferSize As Integer = yres * stride

                    ' We need to be on the UI thread to write to our bitmap
                    ' Not very efficient, but this is just an example
                    Dispatcher.BeginInvoke(New Action(Sub()
                                                          ' resize the writeable if needed
                                                          If VideoBitmap Is Nothing OrElse VideoBitmap.PixelWidth <> xres OrElse VideoBitmap.PixelHeight <> yres OrElse VideoBitmap.DpiX <> dpiX Then
                                                              VideoBitmap = New WriteableBitmap(xres, yres, dpiX, 96.0, PixelFormats.Pbgra32, Nothing)
                                                              VideoSurface.Source = VideoBitmap
                                                          End If

                                                          ' update the writeable bitmap
                                                          VideoBitmap.WritePixels(New Int32Rect(0, 0, xres, yres), videoFrame.p_data, bufferSize, stride)

                                                          ' free frames that were received AFTER use!
                                                          ' This writepixels call is dispatched, so we must do it inside this scope.
                                                          NDIlib.recv_free_video_v2(_recvInstancePtr, videoFrame)

                                                      End Sub))

                    Exit Select

                    ' audio is beyond the scope of this example
                Case NDIlib.frame_type_e.frame_type_audio

                    ' if no audio, nothing to do
                    If audioFrame.p_data = IntPtr.Zero OrElse audioFrame.no_samples = 0 Then
                        ' alreays free received frames
                        NDIlib.recv_free_audio_v2(_recvInstancePtr, audioFrame)

                        Exit Select
                    End If

                    ' if the audio format changed, we need to reconfigure the audio device
                    Dim formatChanged As Boolean = False

                    ' make sure our format has been created and matches the incomming audio
                    If _waveFormat Is Nothing OrElse _waveFormat.Channels <> audioFrame.no_channels OrElse _waveFormat.SampleRate <> audioFrame.sample_rate Then
                        ' Create a wavformat that matches the incomming frames
                        _waveFormat = WaveFormat.CreateIeeeFloatWaveFormat(CInt(audioFrame.sample_rate), CInt(audioFrame.no_channels))

                        formatChanged = True
                    End If

                    ' set up our audio buffer if needed
                    If _bufferedProvider Is Nothing OrElse formatChanged Then
                        _bufferedProvider = New BufferedWaveProvider(_waveFormat)
                        _bufferedProvider.DiscardOnBufferOverflow = True
                    End If

                    ' set up our multiplexer used to mix down to 2 output channels)
                    If _multiplexProvider Is Nothing OrElse formatChanged Then
                        _multiplexProvider = New MultiplexingWaveProvider(New List(Of IWaveProvider)() From {
                            _bufferedProvider
                        }, 2)
                    End If

                    ' set up our audio output device
                    If _wasapiOut Is Nothing OrElse formatChanged Then
                        ' We can't guarantee audio sync or buffer fill, that's beyond the scope of this example.
                        ' This is close enough to show that audio is received and converted correctly.
                        _wasapiOut = New WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.[Shared], 50)
                        _wasapiOut.Init(_multiplexProvider)
                        _wasapiOut.Play()
                    End If

                    ' we're working in bytes, so take the size of a 32 bit sample (float) into account
                    Dim sizeInBytes As Integer = CInt(audioFrame.no_samples) * CInt(audioFrame.no_channels) * 4

                    ' NAudio is expecting interleaved audio and NDI uses planar.
                    ' create an interleaved frame and convert from the one we received
                    Dim interleavedFrame As New NDIlib.audio_frame_interleaved_32f_t() With {
                        .sample_rate = audioFrame.sample_rate,
                        .no_channels = audioFrame.no_channels,
                        .no_samples = audioFrame.no_samples,
                        .timecode = audioFrame.timecode
                    }

                    ' we need a managed byte array to add to buffered provider
                    Dim audBuffer As Byte() = New Byte(sizeInBytes - 1) {}

                    ' pin the byte[] and get a GC handle to it
                    ' doing it this way saves an expensive Marshal.Alloc/Marshal.Copy/Marshal.Free later
                    ' the data will only be moved once, during the fast interleave step that is required anyway
                    Dim handle As GCHandle = GCHandle.Alloc(audBuffer, GCHandleType.Pinned)

                    ' access it by an IntPtr and use it for our interleaved audio buffer
                    interleavedFrame.p_data = handle.AddrOfPinnedObject()

                    ' Convert from float planar to float interleaved audio
                    ' There is a matching version of this that converts to interleaved 16 bit audio frames if you need 16 bit
                    NDIlib.util_audio_to_interleaved_32f_v2(audioFrame, interleavedFrame)

                    ' release the pin on the byte[]
                    ' never try to access p_data after the byte[] has been unpinned!
                    ' that IntPtr will no longer be valid.
                    handle.Free()

                    ' push the byte[] buffer into the bufferedProvider for output
                    _bufferedProvider.AddSamples(audBuffer, 0, sizeInBytes)

                    ' free the frame that was received
                    NDIlib.recv_free_audio_v2(_recvInstancePtr, audioFrame)

                    Exit Select
                    ' Metadata
                Case NDIlib.frame_type_e.frame_type_metadata

                    ' UTF-8 strings must be converted for use - length includes the terminating zero
                    'String metadata = Utf8ToString(metadataFrame.p_data, metadataFrame.length-1);

                    'System.Diagnostics.Debug.Print(metadata);

                    ' free frames that were received
                    NDIlib.recv_free_metadata(_recvInstancePtr, metadataFrame)
                    Exit Select
            End Select
        End While
    End Sub

#End Region


#Region "PrivateMembers"

    ' a pointer to our unmanaged NDI finder instance
    Private _findInstancePtr As IntPtr = IntPtr.Zero

    ' a pointer to our unmanaged NDI receiver instance
    Private _recvInstancePtr As IntPtr = IntPtr.Zero

    ' a thread to receive frames on so that the UI is still functional
    Private _receiveThread As Thread = Nothing

    ' a way to exit the thread safely
    Private _exitThread As Boolean = False

    ' a map of names to sources
    Private _sources As Dictionary(Of [String], NDIlib.source_t) = New Dictionary(Of String, NDIlib.source_t)()

    ' the NAudio related
    Private _wasapiOut As WasapiOut = Nothing
    Private _multiplexProvider As MultiplexingWaveProvider = Nothing
    Private _bufferedProvider As BufferedWaveProvider = Nothing

    ' The last WaveFormat we used.
    ' This may change over time, so remember how we are configured currently.
    Private _waveFormat As WaveFormat = Nothing

#End Region

End Class
