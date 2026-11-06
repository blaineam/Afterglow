using System.IO;
using Unity.Collections;
using UnityEngine;

namespace Afterglow.Hands
{
    // Writes what the hand models were given to PNGs in the app's folder, for reading on a Mac
    // when hands aren't found on the phone: the whole camera image, the detector's letterboxed
    // input and the landmarker's crop, each the way up the model saw it. Switched on with the
    // handDump launch option (how many crops to keep), off otherwise, since every write stalls a
    // frame. Pure apart from the files.
    public static class HandDump
    {
        public const string FolderName = "HandDumps";

        public static string Folder => Path.Combine(Application.persistentDataPath, FolderName);

        // A model input (RGB floats 0..1, first row the top) as a PNG.
        public static string SaveInput(float[] rgb, int size, string name)
        {
            var texture = FromInput(rgb, size);
            try
            {
                return Write(texture, name);
            }
            finally
            {
                Object.Destroy(texture);
            }
        }

        // The camera image (RGBA bytes, first row the top), shrunk by `step` to keep the file small.
        public static string SaveImage(NativeArray<byte> rgba, int width, int height, int step, string name)
        {
            var texture = FromImage(rgba, width, height, step);
            try
            {
                return Write(texture, name);
            }
            finally
            {
                Object.Destroy(texture);
            }
        }

        // Unity's first row is the bottom, so rows are turned over to keep the picture upright.
        public static Texture2D FromInput(float[] rgb, int size)
        {
            var texture = new Texture2D(size, size, TextureFormat.RGB24, false);
            var pixels = new Color32[size * size];
            for (var y = 0; y < size; y++)
            {
                for (var x = 0; x < size; x++)
                {
                    var i = (y * size + x) * 3;
                    pixels[(size - 1 - y) * size + x] = new Color32(To8(rgb[i]), To8(rgb[i + 1]), To8(rgb[i + 2]), 255);
                }
            }
            texture.SetPixels32(pixels);
            texture.Apply(false);
            return texture;
        }

        public static Texture2D FromImage(NativeArray<byte> rgba, int width, int height, int step)
        {
            step = Mathf.Max(1, step);
            var outWidth = width / step;
            var outHeight = height / step;
            var texture = new Texture2D(outWidth, outHeight, TextureFormat.RGB24, false);
            var pixels = new Color32[outWidth * outHeight];
            for (var y = 0; y < outHeight; y++)
            {
                for (var x = 0; x < outWidth; x++)
                {
                    var i = ((y * step) * width + x * step) * 4;
                    pixels[(outHeight - 1 - y) * outWidth + x] = new Color32(rgba[i], rgba[i + 1], rgba[i + 2], 255);
                }
            }
            texture.SetPixels32(pixels);
            texture.Apply(false);
            return texture;
        }

        static byte To8(float value) => (byte)Mathf.Clamp(Mathf.RoundToInt(value * 255f), 0, 255);

        static string Write(Texture2D texture, string name)
        {
            Directory.CreateDirectory(Folder);
            var path = Path.Combine(Folder, name + ".png");
            File.WriteAllBytes(path, texture.EncodeToPNG());
            return path;
        }
    }
}
