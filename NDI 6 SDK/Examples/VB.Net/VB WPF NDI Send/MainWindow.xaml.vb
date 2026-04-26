Imports System.Windows
Imports System.Windows.Media
Imports System.Windows.Media.Animation

' No NDI specific code is in this file.
' Everything is handled in xaml using NdiSendContainer.
' Animation taken directly from example at:
' https://joshsmithonwpf.wordpress.com/2007/08/13/animating-text-in-wpf/
Partial Public Class MainWindow
    Inherits Window
    Public Sub New()
        InitializeComponent()
    End Sub

    ''' <summary>
    ''' Handles the Loaded event of the TextBlock.
    ''' </summary>
    Private Sub StartTextAnimations(sender As Object, e As RoutedEventArgs)
        Me.textBlk.TextEffects = New TextEffectCollection()

        Dim storyBoardWave As New Storyboard()

        Dim storyBoardRotation As New Storyboard()
        storyBoardRotation.RepeatBehavior = RepeatBehavior.Forever
        storyBoardRotation.AutoReverse = True

        For i As Integer = 0 To Me.textBlk.Text.Length - 1
            ' Add a TextEffect for the current character
            ' so that it can be animated.
            Me.AddTextEffectForCharacter(i)

            ' Add an animation which makes the 
            ' character float up and down.
            Me.AddWaveAnimation(storyBoardWave, i)

            ' Add an animation which makes the character rotate.
            Me.AddRotationAnimation(storyBoardRotation, i)
        Next

        ' Add the animation which creates 
        ' a pause between rotations.
        Dim pause As Timeline = TryCast(Me.FindResource("CharacterRotationPauseAnimation"), Timeline)

        storyBoardRotation.Children.Add(pause)

        ' Start the animations 
        storyBoardWave.Begin(Me)
        storyBoardRotation.Begin(Me)
    End Sub

    ''' <summary>
    ''' Adds a TextEffect for the specified character 
    ''' which contains the transforms necessary for 
    ''' animations to be applied.
    ''' </summary>
    Private Sub AddTextEffectForCharacter(charIndex As Integer)
        Dim effect As New TextEffect()

        ' Tell the effect which character 
        ' it applies to in the text.
        effect.PositionStart = charIndex
        effect.PositionCount = 1

        Dim transGrp As New TransformGroup()
        transGrp.Children.Add(New TranslateTransform())
        transGrp.Children.Add(New RotateTransform())
        effect.Transform = transGrp

        Me.textBlk.TextEffects.Add(effect)
    End Sub

    Private Sub AddWaveAnimation(storyBoardLocation As Storyboard, charIndex As Integer)
        Dim anim As DoubleAnimation = TryCast(Me.FindResource("CharacterWaveAnimation"), DoubleAnimation)

        Me.SetBeginTime(anim, charIndex)

        Dim path As String = [String].Format("TextEffects[{0}].Transform.Children[0].Y", charIndex)

        Dim propPath As New PropertyPath(path)
        Storyboard.SetTargetProperty(anim, propPath)

        storyBoardLocation.Children.Add(anim)
    End Sub

    ''' <summary>
    ''' Adds an animation to the specified character 
    ''' in the display text so that it participates 
    ''' in the animated rotation effect.
    ''' </summary>
    Private Sub AddRotationAnimation(storyBoardRotation As Storyboard, charIndex As Integer)
        Dim anim As DoubleAnimation = TryCast(Me.FindResource("CharacterRotationAnimation"), DoubleAnimation)

        Me.SetBeginTime(anim, charIndex)

        Dim path As String = [String].Format("TextEffects[{0}].Transform.Children[1].Angle", charIndex)

        Dim propPath As New PropertyPath(path)
        Storyboard.SetTargetProperty(anim, propPath)

        storyBoardRotation.Children.Add(anim)
    End Sub

    Private Sub SetBeginTime(anim As Timeline, charIndex As Integer)
        Dim totalMs As Double = anim.Duration.TimeSpan.TotalMilliseconds
        Dim offset As Double = totalMs / 10
        Dim resolvedOffset As Double = offset * charIndex
        anim.BeginTime = TimeSpan.FromMilliseconds(resolvedOffset)
    End Sub
End Class
