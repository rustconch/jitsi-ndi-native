using System;
using System.Text.RegularExpressions;

namespace NewTek.NDI
{
    public class Source
    {
        // Really only useful for disconnects or for default values
        public Source()
        {
        }

        // Construct from NDIlib.source_t
        public Source(NDIlib.source_t source_t)
        {
            Name = UTF.Utf8ToString(source_t.p_ndi_name);
        }

        // Construct from strings
        public Source(String name)
        {
            Name = name;
        }

        // Copy constructor.
        public Source(Source previousSource)
        {
            Name = previousSource.Name;
            _uri = previousSource._uri;
        }

        // These are purposely 'public get' only because
        // they should not change during the life of a source.
        public String Name
        {
            get { return _name; }
            private set
            {
                if (_name == value)
                    return;

                _name = value;
                _uri = null;

                var match = Regex.Match(_name, @"^(?<device>.*?)\s+\((?<channel>.*)\)$");
                if (match.Success)
                {
                    _computerName = match.Groups["device"].Value;
                    _sourceName = match.Groups["channel"].Value;

                    Uri.TryCreate(string.Format("ndi://{0}/{1}", _computerName, System.Net.WebUtility.UrlEncode(_sourceName)), UriKind.Absolute, out _uri);
                }
            }
        }

        public String ComputerName
        {
            get { return _computerName; }
        }

        public String SourceName
        {
            get { return _sourceName; }
        }

        public Uri Uri
        {
            get { return _uri; }
        }

        public override string ToString()
        {
            return Name;
        }

        private String _name = String.Empty;
        private String _computerName = String.Empty;
        private String _sourceName = String.Empty;
        private Uri _uri = null;
    }
}
