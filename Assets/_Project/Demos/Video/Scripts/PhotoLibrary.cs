using System;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace Afterglow.Demos.Video
{
    // The user's Photos library (Plugins/iOS/AfterglowPhotoLibrary.mm): every photo and video,
    // newest first, with what each is, a thumbnail on request, and the pictures themselves when
    // one is opened. iOS only; everywhere else this reports an empty library rather than being
    // compiled out at its call sites.
    //
    // A spatial photo, which an iPhone 15 Pro and later record as one HEIC holding a picture per
    // eye, is the one source of 3D the user already has a library of, taken on the same phone that
    // goes in the viewer. A panorama is a cylinder of a picture; a 2:1 still wraps all the way
    // round; a plain photo belongs on a screen. The player tells them apart from Item.
    //
    // Loading is asynchronous: Open starts it and PhotoState says when the pictures are there,
    // because a picture is opened by a pinch while the headset is drawing and a synchronous
    // library fetch would hold up a frame.
    public static class PhotoLibrary
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

        [Flags]
        public enum Kind
        {
            None = 0,
            Video = 1,
            Spatial = 2,
            Panorama = 4,
        }

        // What one item in the library is, enough to list it and know how to open it.
        public readonly struct Item
        {
            public readonly int Index;
            public readonly string Title;
            public readonly Kind Kind;
            public readonly int Width;
            public readonly int Height;
            public readonly double Seconds;

            public Item(int index, string title, Kind kind, int width, int height, double seconds)
            {
                Index = index;
                Title = title;
                Kind = kind;
                Width = width;
                Height = height;
                Seconds = seconds;
            }

            public bool IsVideo => (Kind & Kind.Video) != 0;
            public bool IsSpatial => (Kind & Kind.Spatial) != 0;
            public bool IsPanorama => (Kind & Kind.Panorama) != 0;
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
            return (Access)Afterglow_SpatialAuthorize();
#else
            return Access.Denied;
#endif
        }

        // Every photo and video in the library, newest first. Empty when the library can't be read
        // yet, which is not an error: Authorize may still be asking.
        public static Item[] Scan()
        {
#if UNITY_IOS && !UNITY_EDITOR
            var count = Afterglow_LibraryScan();
            if (count <= 0)
                return Array.Empty<Item>();

            var items = new Item[count];
            var found = 0;
            var title = new StringBuilder(k_TitleLength);
            for (var index = 0; index < count; index++)
            {
                title.Length = 0;
                if (Afterglow_LibraryItem(index, title, title.Capacity, out var kind, out var width, out var height, out var seconds) == 0)
                    continue;
                items[found++] = new Item(index, title.ToString(), (Kind)kind, width, height, seconds);
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

        // Asks for a thumbnail at most `pixels` across; 0 if it can't be asked for.
        public static int RequestThumbnail(int index, int pixels)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_LibraryRequestThumbnail(index, pixels);
#else
            return 0;
#endif
        }

        // The thumbnail, once it's in, as a texture the caller owns: Ready with it, Loading while
        // not yet, Failed if it isn't coming. The request is released on Ready and Failed.
        public static State TryTakeThumbnail(int request, out Texture2D texture)
        {
            texture = null;
#if UNITY_IOS && !UNITY_EDITOR
            var state = Afterglow_LibraryThumbnail(request, out var bytes, out var width, out var height);
            if (state == 0)
                return State.Loading;
            if (state > 0)
                texture = Upload(bytes, width, height, $"Thumbnail {request}");
            Afterglow_LibraryReleaseThumbnail(request);
            return texture != null ? State.Ready : State.Failed;
#else
            return State.Failed;
#endif
        }

        public static void ReleaseThumbnail(int request)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_LibraryReleaseThumbnail(request);
#endif
        }

        public static State PhotoState =>
#if UNITY_IOS && !UNITY_EDITOR
            (State)Afterglow_SpatialPhotoState();
#else
            State.Idle;
#endif

        // How far an iCloud download has got, 0 to 1, while a picture loads.
        public static float Progress =>
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialPhotoProgress();
#else
            0f;
#endif

        public static string PhotoError =>
#if UNITY_IOS && !UNITY_EDITOR
            Marshal.PtrToStringUTF8(Afterglow_SpatialPhotoError()) ?? "";
#else
            "";
#endif

        // Starts loading one spatial photo's two eyes. False if the item isn't a photo.
        public static bool OpenSpatialPhoto(int index)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_SpatialOpenPhoto(index) != 0;
#else
            return false;
#endif
        }

        // Starts loading one picture, upright and at most maxPixels on its longer side. False if
        // the item isn't a photo.
        public static bool OpenImage(int index, int maxPixels)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_LibraryOpenImage(index, maxPixels) != 0;
#else
            return false;
#endif
        }

        // The picture(s), once PhotoState is Ready, as a texture per eye; right is null for a plain
        // picture. The caller owns them. False if they aren't ready, so this is safe to call every
        // frame while waiting.
        public static bool TryTakeTextures(out Texture2D left, out Texture2D right)
        {
            left = right = null;
#if UNITY_IOS && !UNITY_EDITOR
            if (PhotoState != State.Ready)
                return false;
            left = UploadEye(0);
            right = UploadEye(1);
            return left != null;
#else
            return false;
#endif
        }

        public static void Close()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialClosePhoto();
#endif
        }

        // The same for a picture file of the app's own: a JPEG, PNG or HEIC, a spatial HEIC
        // included. False where the plugin isn't there; the Editor decodes JPEG and PNG itself.
        public static bool OpenFile(string path, int maxPixels)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_FileOpenImage(path, maxPixels) != 0;
#else
            return false;
#endif
        }

        // A picture file's size, the way up it's meant to be seen, from its header; false where
        // it can't be read, which is everywhere but iOS.
        public static bool TryGetFileImageSize(string path, out int width, out int height)
        {
            width = height = 0;
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_FileImageSize(path, out width, out height) != 0;
#else
            return false;
#endif
        }

        // A thumbnail of a picture or video file of the app's own, polled with TryTakeThumbnail.
        public static int RequestFileThumbnail(string path, int pixels)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_FileRequestThumbnail(path, pixels);
#else
            return 0;
#endif
        }

#if UNITY_IOS && !UNITY_EDITOR
        static Texture2D UploadEye(int eye)
        {
            if (Afterglow_SpatialPhotoEye(eye, out var bytes, out var width, out var height) == 0)
                return null;
            return Upload(bytes, width, height, eye == 0 ? "Photo Left" : "Photo Right");
        }

        // The plugin's buffers are tightly packed BGRA starting at the bottom row, which is what
        // Unity's BGRA32 wants, so they upload without being touched.
        static Texture2D Upload(IntPtr bytes, int width, int height, string name)
        {
            if (bytes == IntPtr.Zero || width <= 0 || height <= 0)
                return null;
            var texture = new Texture2D(width, height, TextureFormat.BGRA32, false, false)
            {
                name = name,
                wrapMode = TextureWrapMode.Clamp,
            };
            texture.LoadRawTextureData(bytes, width * height * 4);
            texture.Apply(false, true);
            return texture;
        }

        [DllImport("__Internal")] static extern int Afterglow_SpatialAuthorize();
        [DllImport("__Internal")] static extern int Afterglow_LibraryScan();
        [DllImport("__Internal")] static extern int Afterglow_LibraryItem(int index, StringBuilder title, int titleLength, out int kind, out int width, out int height, out double seconds);
        [DllImport("__Internal")] static extern int Afterglow_LibraryRequestThumbnail(int index, int pixels);
        [DllImport("__Internal")] static extern int Afterglow_LibraryThumbnail(int request, out IntPtr bytes, out int width, out int height);
        [DllImport("__Internal")] static extern void Afterglow_LibraryReleaseThumbnail(int request);
        [DllImport("__Internal")] static extern int Afterglow_LibraryOpenImage(int index, int maxPixels);
        [DllImport("__Internal")] static extern int Afterglow_SpatialOpenPhoto(int index);
        [DllImport("__Internal")] static extern int Afterglow_SpatialPhotoState();
        [DllImport("__Internal")] static extern IntPtr Afterglow_SpatialPhotoError();
        [DllImport("__Internal")] static extern int Afterglow_SpatialPhotoEye(int eye, out IntPtr bytes, out int width, out int height);
        [DllImport("__Internal")] static extern void Afterglow_SpatialClosePhoto();
        [DllImport("__Internal")] static extern float Afterglow_SpatialPhotoProgress();
        [DllImport("__Internal")] static extern int Afterglow_FileOpenImage(string path, int maxPixels);
        [DllImport("__Internal")] static extern int Afterglow_FileImageSize(string path, out int width, out int height);
        [DllImport("__Internal")] static extern int Afterglow_FileRequestThumbnail(string path, int pixels);
#endif
    }
}
