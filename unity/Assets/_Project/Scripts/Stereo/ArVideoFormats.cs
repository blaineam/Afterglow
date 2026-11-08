using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Afterglow.Stereo
{
    // ARKit's video formats with the camera each comes from (Plugins/iOS/AfterglowArFormats.mm),
    // in the order AR Foundation lists its configurations: the iPhone's list holds the same sizes
    // and rates once per camera, and only this says which is the ultra-wide. Empty off iOS.
    public static class ArVideoFormats
    {
        public struct Format
        {
            public int Index;
            public int Width;
            public int Height;
            public int Fps;
            public string Camera;   // wide, ultrawide, telephoto or other

            public override string ToString() => $"{Index}: {Width}x{Height}@{Fps} {Camera}";
        }

        public static List<Format> Read()
        {
#if UNITY_IOS && !UNITY_EDITOR
            var buffer = new StringBuilder(4096);
            Afterglow_ArVideoFormats(buffer, buffer.Capacity);
            return Parse(buffer.ToString());
#else
            return new List<Format>();
#endif
        }

        // "0:1920x1440@60:wide,1:..." as formats; anything malformed is skipped. Pure.
        public static List<Format> Parse(string text)
        {
            var formats = new List<Format>();
            if (string.IsNullOrEmpty(text))
                return formats;
            foreach (var item in text.Split(','))
            {
                var parts = item.Split(':');
                if (parts.Length != 3)
                    continue;
                var size = parts[1].Split('@');
                if (size.Length != 2)
                    continue;
                var dims = size[0].Split('x');
                if (dims.Length != 2)
                    continue;
                if (!int.TryParse(parts[0], out var index) || !int.TryParse(dims[0], out var width) ||
                    !int.TryParse(dims[1], out var height) || !int.TryParse(size[1], out var fps))
                    continue;
                formats.Add(new Format { Index = index, Width = width, Height = height, Fps = fps, Camera = parts[2] });
            }
            return formats;
        }

        // The ultra-wide format to prefer: at the wanted rate, the largest no wider than maxWidth
        // (the hands and passthrough read a 1920-wide image happily; 4K costs for nothing). -1 if
        // the phone has no ultra-wide formats. Pure.
        public static int PreferredUltraWide(List<Format> formats, int fps, int maxWidth)
        {
            var best = -1;
            var bestPixels = 0;
            foreach (var f in formats)
            {
                if (f.Camera != "ultrawide" || f.Fps != fps || f.Width > maxWidth)
                    continue;
                var pixels = f.Width * f.Height;
                if (pixels > bestPixels)
                {
                    bestPixels = pixels;
                    best = f.Index;
                }
            }
            return best;
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_ArVideoFormats(StringBuilder buffer, int capacity);
#endif
    }
}
