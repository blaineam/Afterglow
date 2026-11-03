using System;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace CardboardXR.Demos.Video
{
    // Spatial photos from the user's Photos library (Plugins/iOS/CardboardXRSpatialPhotos.mm).
    //
    // An iPhone 15 Pro and later record a spatial photo as one HEIC holding a picture per eye, so
    // this is the one source of 3D the user already has a library of, taken on the same phone that
    // goes in the viewer. Nothing outside iOS has them, so everywhere else this reports an empty
    // library rather than being compiled out at its call sites.
    //
    // Loading is asynchronous: Open starts it and State says when the pictures are there, because
    // a photo is opened by a pinch while the headset is drawing and a synchronous library fetch
    // would hold up a frame.
    public static class SpatialPhotos
    {
        public enum Access
        {
            Denied = 0,
            Granted = 1,
            Asking = 2,
        }

        public enum State
        {
            Idle = 0,
            Loading = 1,
            Ready = 2,
            Failed = 3,
        }

        // What one spatial item in the library is, enough to list it and know how to open it.
        public readonly struct Item
        {
            public readonly int Index;
            public readonly string Title;
            public readonly bool IsVideo;
            public readonly double Seconds;

            public Item(int index, string title, bool isVideo, double seconds)
            {
                Index = index;
                Title = title;
                IsVideo = isVideo;
                Seconds = seconds;
            }
        }

        const int k_TitleLength = 64;

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        // Asks for the library, or says it has already been granted or refused. The first call puts
        // iOS's dialog up and returns Asking; call it again once the user has answered.
        public static Access Authorize()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return (Access)CardboardXR_SpatialAuthorize();
#else
            return Access.Denied;
#endif
        }

        // Every spatial photo and video in the library, newest first. Empty when the library can't
        // be read yet, which is not an error: Authorize may still be asking.
        public static Item[] Scan()
        {
#if UNITY_IOS && !UNITY_EDITOR
            var count = CardboardXR_SpatialScan();
            if (count <= 0)
                return Array.Empty<Item>();

            var items = new Item[count];
            var found = 0;
            var title = new StringBuilder(k_TitleLength);
            for (var index = 0; index < count; index++)
            {
                title.Length = 0;
                if (CardboardXR_SpatialItem(index, title, title.Capacity, out var isVideo, out var seconds) == 0)
                    continue;
                items[found++] = new Item(index, title.ToString(), isVideo != 0, seconds);
            }
            if (found == items.Length)
                return items;
            var trimmed = new Item[found];
            Array.Copy(items, trimmed, found);
            return trimmed;
#else
            return Array.Empty<Item>();
#endif
        }

        public static State PhotoState =>
#if UNITY_IOS && !UNITY_EDITOR
            (State)CardboardXR_SpatialPhotoState();
#else
            State.Idle;
#endif

        public static string PhotoError =>
#if UNITY_IOS && !UNITY_EDITOR
            Marshal.PtrToStringUTF8(CardboardXR_SpatialPhotoError()) ?? "";
#else
            "";
#endif

        // Starts loading one spatial photo. False if the item isn't a photo this can open.
        public static bool OpenPhoto(int index)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return CardboardXR_SpatialOpenPhoto(index) != 0;
#else
            return false;
#endif
        }

        // The two pictures, once PhotoState is Ready, as a texture per eye. The caller owns them.
        // Null if they aren't ready, so this is safe to call every frame while waiting.
        public static bool TryTakeTextures(out Texture2D left, out Texture2D right)
        {
            left = right = null;
#if UNITY_IOS && !UNITY_EDITOR
            if (PhotoState != State.Ready)
                return false;
            left = Upload(0);
            right = Upload(1);
            if (left != null && right != null)
                return true;
            // One eye without the other is no use, and would be drawn as a flat picture.
            if (left != null)
                UnityEngine.Object.Destroy(left);
            if (right != null)
                UnityEngine.Object.Destroy(right);
            left = right = null;
#endif
            return false;
        }

        public static void Close()
        {
#if UNITY_IOS && !UNITY_EDITOR
            CardboardXR_SpatialClosePhoto();
#endif
        }

#if UNITY_IOS && !UNITY_EDITOR
        // The plugin's buffer is tightly packed BGRA starting at the bottom row, which is what
        // Unity's BGRA32 wants, so it uploads without being touched.
        static Texture2D Upload(int eye)
        {
            if (CardboardXR_SpatialPhotoEye(eye, out var bytes, out var width, out var height) == 0)
                return null;
            if (bytes == IntPtr.Zero || width <= 0 || height <= 0)
                return null;

            var texture = new Texture2D(width, height, TextureFormat.BGRA32, false, false)
            {
                name = $"Spatial Photo {(eye == 0 ? "Left" : "Right")}",
                wrapMode = TextureWrapMode.Clamp,
            };
            texture.LoadRawTextureData(bytes, width * height * 4);
            texture.Apply(false, true);
            return texture;
        }

        [DllImport("__Internal")] static extern int CardboardXR_SpatialAuthorize();
        [DllImport("__Internal")] static extern int CardboardXR_SpatialScan();
        [DllImport("__Internal")] static extern int CardboardXR_SpatialItem(int index, StringBuilder title, int titleLength, out int isVideo, out double seconds);
        [DllImport("__Internal")] static extern int CardboardXR_SpatialOpenPhoto(int index);
        [DllImport("__Internal")] static extern int CardboardXR_SpatialPhotoState();
        [DllImport("__Internal")] static extern IntPtr CardboardXR_SpatialPhotoError();
        [DllImport("__Internal")] static extern int CardboardXR_SpatialPhotoEye(int eye, out IntPtr bytes, out int width, out int height);
        [DllImport("__Internal")] static extern void CardboardXR_SpatialClosePhoto();
#endif
    }
}
