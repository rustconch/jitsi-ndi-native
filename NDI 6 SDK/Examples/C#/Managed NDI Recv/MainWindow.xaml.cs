using NewTek;
using NewTek.NDI;
using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Data;

namespace Managed_NDI_Receive
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();

            // Not required, but "correct". (see the SDK documentation)
            _ndiInitialized = NDIlib.initialize();
            if (!_ndiInitialized)
            {
                // Cannot run NDI. Most likely because the CPU is not sufficient (see SDK documentation).
                // you can check this directly with a call to NDIlib.is_supported_CPU()
                if (!NDIlib.is_supported_CPU())
                {
                    MessageBox.Show("CPU unsupported.");
                }
                else
                {
                    // not sure why, but it's not going to run
                    MessageBox.Show("Cannot run NDI.");
                }

                // we can't go on
                Close();
            }
        }

        private bool _ndiInitialized = false;

        // properly dispose of the unmanaged objects
        protected override void OnClosed(EventArgs e)
        {
            if (ReceiveViewer != null)
                ReceiveViewer.Dispose();

            if (_findInstance != null)
                _findInstance.Dispose();

            if (_ndiInitialized)
            {
                NDIlib.destroy();
                _ndiInitialized = false;
            }

            base.OnClosed(e);
        }

        // This will find NDI sources on the network.
        // Continually updated as new sources arrive.
        // Note that this example does see local sources (new Finder(true))
        // This is for ease of testing, but normally is not needed in released products.
        public Finder FindInstance
        {
            get { return _findInstance; }
        }
        private Finder _findInstance = new Finder(true);
    }
}
