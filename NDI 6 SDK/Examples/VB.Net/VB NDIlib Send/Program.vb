Imports System.Drawing
Imports System.Drawing.Drawing2D
Imports System.Runtime.InteropServices
Imports NewTek
Imports NewTek.NDI

Class Program
    Private Shared Sub DrawPrettyText(graphics As Graphics, text As [String], size As Single, family As FontFamily, origin As Point, format As StringFormat,
        fill As Brush, outline As Pen)
        ' make a text path
        Dim path As New GraphicsPath()
        path.AddString(text, family, 0, size, origin, format)

        ' Draw the pretty text
        graphics.FillPath(fill, path)
        graphics.DrawPath(outline, path)
    End Sub

    ' Because 48kHz audio actually involves 1601.6 samples per frame at 29.97fps, we make a basic sequence that we follow.
    Shared audioNumSamples As Integer() = {1602, 1601, 1602, 1601, 1602}

    ' fills the audio buffer with a test tone or silence
    Private Shared Sub FillAudioBuffer(audioFrame As NDIlib.audio_frame_v2_t, doTone As Boolean)
        ' should never happen
        If audioFrame.p_data = IntPtr.Zero Then
            Return
        End If

        ' temp space for floats
        Dim floatBuffer As Single() = New Single(CInt(audioFrame.no_samples) - 1) {}

        ' make the tone or silence
        Dim cycleLength As Double = CDbl(audioFrame.sample_rate) / 1000.0
        Dim sampleNumber As Integer = 0
        For i As Integer = 0 To CInt(audioFrame.no_samples) - 1
            Dim time As Double = System.Math.Max(System.Threading.Interlocked.Increment(sampleNumber), sampleNumber - 1) / cycleLength
            floatBuffer(i) = If(doTone, CSng(Math.Sin(2.0F * Math.PI * time) * 0.1), 0.0F)
        Next

        ' fill each channel with our floats...
        For ch As Integer = 0 To CInt(audioFrame.no_channels) - 1
            ' scary pointer math ahead...
            ' where does this channel start in the unmanaged buffer?
            Dim destStart As New IntPtr(audioFrame.p_data.ToInt64() + (ch * audioFrame.channel_stride_in_bytes))

            ' copy the float array into the channel
            Marshal.Copy(floatBuffer, 0, destStart, CInt(audioFrame.no_samples))
        Next
    End Sub

    Friend Shared Sub Main()
        ' .Net interop doesn't handle UTF-8 strings, so do it manually
        ' These must be freed later
        Dim sourceNamePtr As IntPtr = UTF.StringToUtf8("VB.Net Example")

        Dim groupsNamePtr As IntPtr = IntPtr.Zero

        ' Not required, but "correct". (see the SDK documentation)
        If Not NDIlib.initialize() Then
            ' Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
            ' you can check this directly with a call to NDIlib_is_supported_CPU()
            Console.WriteLine("Cannot run NDI")
            Return
        End If

        ' Create an NDI source description using sourceNamePtr and it's clocked to the video.
        Dim createDesc As New NDIlib.send_create_t() With {
            .p_ndi_name = sourceNamePtr,
            .p_groups = groupsNamePtr,
            .clock_video = True,
            .clock_audio = False
        }

        ' We create the NDI finder instance
        Dim sendInstancePtr As IntPtr = NDIlib.send_create(createDesc)

        ' free the strings we allocated
        Marshal.FreeHGlobal(sourceNamePtr)
        Marshal.FreeHGlobal(groupsNamePtr)

        ' did it succeed?
        If sendInstancePtr = IntPtr.Zero Then
            Console.WriteLine("Failed to create send instance")
            Return
        End If

        ' define our bitmap properties
        Dim xres As Integer = 1920
        Dim yres As Integer = 1080
        'BGRA bpp
        Dim stride As Integer = CInt(Math.Truncate((xres * 32 + 7) / 8))
        Dim bufferSize As Integer = yres * stride

        ' allocate some memory for a video buffer
        Dim bufferPtr As IntPtr = Marshal.AllocHGlobal(CInt(bufferSize))

        ' We are going to create a 1920x1080 progressive frame at 29.97Hz.
        ' Resolution
        ' Use BGRA video
        ' The frame-eate
        ' The aspect ratio (16:9)
        ' This is a progressive frame
        ' Timecode.
        ' The video memory used for this frame
        ' The line to line stride of this image
        Dim videoFrame As New NDIlib.video_frame_v2_t() With {
            .xres = xres,
            .yres = yres,
            .FourCC = NDIlib.FourCC_type_e.FourCC_type_BGRA,
            .frame_rate_N = 30000,
            .frame_rate_D = 1001,
            .picture_aspect_ratio = (16.0F / 9.0F),
            .frame_format_type = NDIlib.frame_format_type_e.frame_format_type_progressive,
            .timecode = NDIlib.send_timecode_synthesize,
            .p_data = bufferPtr,
            .line_stride_in_bytes = CInt(stride),
            .p_metadata = IntPtr.Zero,
            .timestamp = 0
        }

        ' set up an audio frame
        ' 48kHz in our example
        ' Lets submit stereo although there is nothing limiting us
        ' There can be up to 1602 samples at 29.97fps, we'll change this on the fly
        ' Timecode (synthesized for us !)
        ' The inter channel stride - this will also change on the fly
        Dim audioFrame As New NDIlib.audio_frame_v2_t() With {
            .sample_rate = 48000,
            .no_channels = 2,
            .no_samples = 1602,
            .timecode = NDIlib.send_timecode_synthesize,
            .channel_stride_in_bytes = 4 * 1602,
            .p_metadata = IntPtr.Zero,
            .timestamp = NDIlib.recv_timestamp_undefined
        }

        ' allocate some unmanaged memory for an audio buffer
        ' we're allocating more than needed for any number of samples we might need
        audioFrame.p_data = Marshal.AllocHGlobal(CInt(audioFrame.no_channels) * 2000 * 4)

        ' get a compatible bitmap and graphics context
        Dim bmp As New Bitmap(CInt(xres), CInt(yres), CInt(stride), System.Drawing.Imaging.PixelFormat.Format32bppPArgb, bufferPtr)
        Dim graphics As Graphics = Graphics.FromImage(bmp)
        graphics.SmoothingMode = SmoothingMode.AntiAlias

        ' We'll use these later inside the loop
        Dim textFormat As New StringFormat()
        textFormat.Alignment = StringAlignment.Center
        textFormat.LineAlignment = StringAlignment.Center

        Dim fontFamily As New FontFamily("Arial")
        Dim outlinePen As New Pen(Color.Black, 2.0F)
        Dim thinOutlinePen As New Pen(Color.Black, 1.0F)

        ' We will send 10000 frames of video.
        For frameNumber As Integer = 0 To 9999
            ' are we connected to anyone?
            If NDIlib.send_get_no_connections(sendInstancePtr, 10000) < 1 Then
                ' no point rendering
                Console.WriteLine("No current connections, so no rendering needed.")

                ' Wait a bit, otherwise our limited example will end before you can connect to it
                System.Threading.Thread.Sleep(50)
            Else
                ' Because we are clocking to the video it is better to always submit the audio
                ' before, although there is very little in it. I'll leave it as an excercise for the
                ' reader to work out why.
                audioFrame.no_samples = audioNumSamples(frameNumber Mod 5)
                audioFrame.channel_stride_in_bytes = CInt(audioFrame.no_samples * 4)

                ' put tone in it every 30 frames
                Dim doTone As Boolean = frameNumber Mod 30 = 0
                FillAudioBuffer(audioFrame, doTone)

                ' Submit the audio buffer
                NDIlib.send_send_audio_v2(sendInstancePtr, audioFrame)

                ' fill it with a lovely color
                graphics.Clear(Color.Maroon)

                ' show which source we are
                DrawPrettyText(graphics, "VB Example Source", 96.0F, fontFamily, New Point(960, 100), textFormat,
                    Brushes.White, outlinePen)

                ' Get the tally state of this source (we poll it),
                Dim NDI_tally As New NDIlib.tally_t()
                NDIlib.send_get_tally(sendInstancePtr, NDI_tally, 0)

                ' Do something different depending on where we are shown
                If NDI_tally.on_program Then
                    DrawPrettyText(graphics, "On Program", 96.0F, fontFamily, New Point(960, 225), textFormat,
                        Brushes.White, outlinePen)
                ElseIf NDI_tally.on_preview Then
                    DrawPrettyText(graphics, "On Preview", 96.0F, fontFamily, New Point(960, 225), textFormat,
                        Brushes.White, outlinePen)
                End If

                '''/ show what frame we've rendered
                DrawPrettyText(graphics, [String].Format("Frame {0}", frameNumber.ToString()), 96.0F, fontFamily, New Point(960, 350), textFormat,
                    Brushes.White, outlinePen)

                ' show current time
                DrawPrettyText(graphics, System.DateTime.Now.ToString(), 96.0F, fontFamily, New Point(960, 900), textFormat,
                    Brushes.White, outlinePen)

                ' We now submit the frame. Note that this call will be clocked so that we end up submitting 
                ' at exactly 29.97fps.
                NDIlib.send_send_video_v2(sendInstancePtr, videoFrame)

                ' Just display something helpful in the console
                Console.WriteLine("Frame number {0} sent.", frameNumber)
            End If
        Next

        ' Dispose of our graphics resources
        graphics.Dispose()
        bmp.Dispose()

        ' free our buffers
        Marshal.FreeHGlobal(bufferPtr)
        Marshal.FreeHGlobal(audioFrame.p_data)

        ' Destroy the NDI sender
        NDIlib.send_destroy(sendInstancePtr)

        ' Not required, but "correct". (see the SDK documentation)
        NDIlib.destroy()
    End Sub
End Class
