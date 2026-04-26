using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

// No NDI specific code is in this file.
// Everything is handled in xaml using NdiSendContainer.
// Animation taken directly from example at:
// https://joshsmithonwpf.wordpress.com/2007/08/13/animating-text-in-wpf/
namespace WPF_NDI_Send
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();
        }

        // If clicked, it will toggle sending system audio through NDI on and off
        void NdiSender_MouseUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
        {
            NdiSender.SendSystemAudio = !NdiSender.SendSystemAudio;
        }

        void MainWindow_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            // if you don't dispose of it, WPF won't clean it up fully.
            NdiSender.Dispose();
        }

        /// <summary>
        /// Handles the Loaded event of the TextBlock.
        /// </summary>
        void StartTextAnimations(object sender, RoutedEventArgs e)
        {
            this.textBlk.TextEffects = new TextEffectCollection();

            Storyboard storyBoardWave = new Storyboard();

            Storyboard storyBoardRotation = new Storyboard();
            storyBoardRotation.RepeatBehavior = RepeatBehavior.Forever;
            storyBoardRotation.AutoReverse = true;

            for (int i = 0; i < this.textBlk.Text.Length; ++i)
            {
                // Add a TextEffect for the current character
                // so that it can be animated.
                this.AddTextEffectForCharacter(i);

                // Add an animation which makes the 
                // character float up and down.
                this.AddWaveAnimation(storyBoardWave, i);

                // Add an animation which makes the character rotate.
                this.AddRotationAnimation(storyBoardRotation, i);
            }

            // Add the animation which creates 
            // a pause between rotations.
            Timeline pause =
                this.FindResource("CharacterRotationPauseAnimation")
                as Timeline;

            storyBoardRotation.Children.Add(pause);

            // Start the animations 
            storyBoardWave.Begin(this);
            storyBoardRotation.Begin(this);
        }

        /// <summary>
        /// Adds a TextEffect for the specified character 
        /// which contains the transforms necessary for 
        /// animations to be applied.
        /// </summary>
        void AddTextEffectForCharacter(int charIndex)
        {
            TextEffect effect = new TextEffect();

            // Tell the effect which character 
            // it applies to in the text.
            effect.PositionStart = charIndex;
            effect.PositionCount = 1;

            TransformGroup transGrp = new TransformGroup();
            transGrp.Children.Add(new TranslateTransform());
            transGrp.Children.Add(new RotateTransform());
            effect.Transform = transGrp;

            this.textBlk.TextEffects.Add(effect);
        }

        void AddWaveAnimation(Storyboard storyBoardLocation, int charIndex)
        {
            DoubleAnimation anim =
                this.FindResource("CharacterWaveAnimation")
                as DoubleAnimation;

            this.SetBeginTime(anim, charIndex);

            string path = String.Format(
                "TextEffects[{0}].Transform.Children[0].Y",
                charIndex);

            PropertyPath propPath = new PropertyPath(path);
            Storyboard.SetTargetProperty(anim, propPath);

            storyBoardLocation.Children.Add(anim);
        }

        /// <summary>
        /// Adds an animation to the specified character 
        /// in the display text so that it participates 
        /// in the animated rotation effect.
        /// </summary>
        void AddRotationAnimation(
            Storyboard storyBoardRotation, int charIndex)
        {
            DoubleAnimation anim =
                this.FindResource("CharacterRotationAnimation")
                as DoubleAnimation;

            this.SetBeginTime(anim, charIndex);

            string path = String.Format(
                "TextEffects[{0}].Transform.Children[1].Angle",
                charIndex);

            PropertyPath propPath = new PropertyPath(path);
            Storyboard.SetTargetProperty(anim, propPath);

            storyBoardRotation.Children.Add(anim);
        }

        void SetBeginTime(Timeline anim, int charIndex)
        {
            double totalMs = anim.Duration.TimeSpan.TotalMilliseconds;
            double offset = totalMs / 10;
            double resolvedOffset = offset * charIndex;
            anim.BeginTime = TimeSpan.FromMilliseconds(resolvedOffset);
        }

    }
}
