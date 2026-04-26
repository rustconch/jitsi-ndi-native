Imports NewTek
Imports NewTek.NDI
Imports System.ComponentModel
Imports System.Windows
Imports System.Windows.Data
Imports System.Linq
Imports System.Windows.Controls
Imports System.Windows.Controls.Primitives

Partial Public Class MainWindow
    Inherits Window
    Public Sub New()
        InitializeComponent()

        ' Not required, but "correct". (see the SDK documentation)
        If Not NDIlib.initialize() Then
            ' Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
            ' you can check this directly with a call to NDIlib.is_supported_CPU()
            If Not NDIlib.is_supported_CPU() Then
                MessageBox.Show("CPU unsupported.")
            Else
                ' not sure why, but it's not going to run
                MessageBox.Show("Cannot run NDI.")
            End If

            ' we can't go on
            Close()
        End If
    End Sub

    ' properly dispose of the unmanaged objects
    Protected Overrides Sub OnClosed(e As EventArgs)
        If _routerInstance IsNot Nothing Then
            _routerInstance.Dispose()
        End If

        If _findInstance IsNot Nothing Then
            _findInstance.Dispose()
        End If

        MyBase.OnClosed(e)
    End Sub

    ' This will find NDI sources on the network.
    ' Continually updated as new sources arrive.
    ' Note that this example does see local sources (new Finder(true))
    ' This is for ease of testing, but normally is not needed in released products.
    Public ReadOnly Property FindInstance() As Finder
        Get
            Return _findInstance
        End Get
    End Property
    Private _findInstance As New Finder(True)


    ' we need a router instance
    Public ReadOnly Property RouterInstance() As Router
        Get
            Return _routerInstance
        End Get
    End Property

    ' we give our router a name here, but it can be changed later if needed
    Private _routerInstance As New Router("Router Example")
End Class