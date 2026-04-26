using NewTek;
using NewTek.NDI;
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Managed_NDI_Send_Example
{
    class Program
    {
        static void DrawPrettyText(Graphics graphics, String text, float size, FontFamily family, Point origin, StringFormat format, Brush fill, Pen outline)
        {
            // make a text path
            GraphicsPath path = new GraphicsPath();
            path.AddString(text, family, 0, size, origin, format);

            // Draw the pretty text
            graphics.FillPath(fill, path);
            graphics.DrawPath(outline, path);
        }

        // Because 48kHz audio actually involves 1601.6 samples per frame at 29.97fps, we make a basic sequence that we follow.
        static int[] audioNumSamples = { 1602, 1601, 1602, 1601, 1602 };

        // fills the audio buffer with a test tone or silence
        static void FillAudioBuffer(AudioFrame audioFrame, bool doTone)
        {
            // should never happen
            if (audioFrame.AudioBuffer == IntPtr.Zero)
                return;

            // temp space for floats
            float[] floatBuffer = new float[audioFrame.NumSamples];

            // make the tone or silence
            double cycleLength = (double)audioFrame.SampleRate / 1000.0;
            int sampleNumber = 0;
            for (int i = 0; i < audioFrame.NumSamples; i++)
            {
                double time = sampleNumber++ / cycleLength;
                floatBuffer[i] = doTone ? (float)(Math.Sin(2.0f * Math.PI * time) * 0.1) : 0.0f;
            }

            // fill each channel with our floats...
            for (int ch = 0; ch < audioFrame.NumChannels; ch++)
            {
                // scary pointer math ahead...
                // where does this channel start in the unmanaged buffer?
                IntPtr destStart = new IntPtr(audioFrame.AudioBuffer.ToInt64() + (ch * audioFrame.ChannelStride));

                // copy the float array into the channel
                Marshal.Copy(floatBuffer, 0, destStart, audioFrame.NumSamples);
            }
        }

        static void Main()
        {
            // Note that some of these using statements are sharing the same scope and
            // will be disposed together simply because I dislike deeply nested scopes.
            // You can manually handle .Dispose() for longer lived objects or use any pattern you prefer.

            // When creating the sender use the Managed NDIlib Send example as the failover for this sender
            // Therefore if you run both examples and then close this one it demonstrates failover in action
            String failoverName = String.Format("{0} (NDIlib Send Example)", System.Net.Dns.GetHostName());

            // this will show up as a source named "Example" with all other settings at their defaults
            using (Sender sendInstance = new Sender("Example", true, false, null, failoverName))
            {
                // We are going to create a 1920x1080 16:9 frame at 29.97Hz, progressive (default).
                // We are also going to create an audio frame with enough for 1700 samples for a bit of safety,
                // but 1602 should be enough using our settings as long as we don't overrun the buffer.
                // 48khz, stereo in the example.
                using (VideoFrame videoFrame = new VideoFrame(1920, 1080, (16.0f / 9.0f), 30000, 1001))
                using (AudioFrame audioFrame = new AudioFrame(1700, 48000, 2))
                {
                    // get a compatible bitmap and graphics context from our video frame.
                    // also sharing a using scope.
                    using (Bitmap bmp = new Bitmap(videoFrame.Width, videoFrame.Height, videoFrame.Stride, System.Drawing.Imaging.PixelFormat.Format32bppPArgb, videoFrame.BufferPtr))
                    using (Graphics graphics = Graphics.FromImage(bmp))
                    {
                        graphics.SmoothingMode = SmoothingMode.AntiAlias;

                        // We'll use these later inside the loop
                        StringFormat textFormat = new StringFormat();
                        textFormat.Alignment = StringAlignment.Center;
                        textFormat.LineAlignment = StringAlignment.Center;

                        FontFamily fontFamily = new FontFamily("Arial");
                        Pen outlinePen = new Pen(Color.Black, 2.0f);
                        Pen thinOutlinePen = new Pen(Color.Black, 1.0f);

                        // We will send 10000 frames of video.
                        for (int frameNumber = 0; frameNumber < 10000; frameNumber++)
                        {
                            // are we connected to anyone?
                            if (sendInstance.GetConnections(10000) < 1)
                            {
                                // no point rendering
                                Console.WriteLine("No current connections, so no rendering needed.");

                                // Wait a bit, otherwise our limited example will end before you can connect to it
                                System.Threading.Thread.Sleep(50);
                            }
                            else
                            {
                                // Because we are clocking to the video it is better to always submit the audio
                                // before, although there is very little in it. I'll leave it as an excercise for the
                                // reader to work out why.
                                audioFrame.NumSamples = audioNumSamples[frameNumber % 5];
                                audioFrame.ChannelStride = audioFrame.NumSamples * sizeof(float);

                                // put tone in it every 30 frames
                                bool doTone = frameNumber % 30 == 0;
                                FillAudioBuffer(audioFrame, doTone);

                                // Submit the audio buffer
                                sendInstance.Send(audioFrame);

                                // fill it with a lovely color
                                graphics.Clear(Color.Maroon);

                                // show which source we are
                                DrawPrettyText(graphics, "C# Example Source", 96.0f, fontFamily, new Point(960, 100), textFormat, Brushes.White, outlinePen);

                                // Get the tally state of this source (we poll it),
                                // This gets a snapshot of the current tally state.
                                // Accessing sendInstance.Tally directly would make an API call
                                // for each "if" below and could cause inaccurate results.
                                NDIlib.tally_t NDI_tally = sendInstance.Tally;

                                // Do something different depending on where we are shown
                                if (NDI_tally.on_program)
                                    DrawPrettyText(graphics, "On Program", 96.0f, fontFamily, new Point(960, 225), textFormat, Brushes.White, outlinePen);
                                else if (NDI_tally.on_preview)
                                    DrawPrettyText(graphics, "On Preview", 96.0f, fontFamily, new Point(960, 225), textFormat, Brushes.White, outlinePen);

                                //// show what frame we've rendered
                                DrawPrettyText(graphics, String.Format("Frame {0}", frameNumber.ToString()), 96.0f, fontFamily, new Point(960, 350), textFormat, Brushes.White, outlinePen);

                                // show current time
                                DrawPrettyText(graphics, System.DateTime.Now.ToString(), 96.0f, fontFamily, new Point(960, 900), textFormat, Brushes.White, outlinePen);

                                // We now submit the frame. Note that this call will be clocked so that we end up submitting 
                                // at exactly 29.97fps.
                                sendInstance.Send(videoFrame);

                                // Just display something helpful in the console
                                Console.WriteLine("Frame number {0} sent.", frameNumber);
                            }

                        } // for loop - frameNumber

                    } // using bmp and graphics

                } // using audioFrame and videoFrame

            } // using sendInstance

        } // Main
    }
}
