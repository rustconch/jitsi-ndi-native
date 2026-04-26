using NewTek;
using NewTek.NDI;
using System.ComponentModel;
using System.Windows;
using System.Windows.Data;
using System.Linq;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System;

namespace Managed_NDI_Router
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();

            // Not required, but "correct". (see the SDK documentation)
            if (!NDIlib.initialize())
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

        // properly dispose of the unmanaged objects
        protected override void OnClosed(EventArgs e)
        {
            if (_routerInstance != null)
                _routerInstance.Dispose();

            if (_findInstance != null)
                _findInstance.Dispose();

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


        // we need a router instance
        public Router RouterInstance
        {
            get { return _routerInstance; }
        }

        // we give our router a name here, but it can be changed later if needed
        private Router _routerInstance = new Router("Router Example");
    }
}
