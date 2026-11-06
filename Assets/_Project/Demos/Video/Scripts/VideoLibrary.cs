using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;

namespace Afterglow.Demos.Video
{
    // What one item is, which says how it's opened and what it's drawn on.
    public enum MediaKind
    {
        // A video file: bundled, copied into the Videos folder, or a Drive download.
        File,
        // A Google Drive link, downloaded into the cache before it plays.
        Drive,
        // A plain photo from the Photos library, shown on a screen ahead.
        Photo,
        // A 2:1 still from the library, wrapped all the way round.
        Still360,
        // A panorama from the library, on a cylinder as wide as it was shot.
        Panorama,
        // An ordinary video from the library, played from its file.
        LibraryVideo,
        // A spatial photo: one picture per eye, decoded by the plugin.
        SpatialPhoto,
        // A spatial video: two views in one file, decoded by the plugin.
        SpatialVideo,
    }

    // The media browser's filters.
    public enum MediaFilter
    {
        All,
        Spatial,
        Panoramas,
        Still360,
        Videos,
    }

    // One photo or video the player can show.
    public class VideoEntry
    {
        public string Title;
        public VideoFormat Format;
        // Something VideoPlayer.url takes: a file path, or a StreamingAssets path (inside the APK on
        // Android). Null until a Drive video is downloaded or a library video's file is asked for.
        public string Url;
        // A Google Drive file, downloaded into the cache before it plays.
        public string DriveId;
        // Where a download stands, while one runs or after one failed.
        public string Status;
        public MediaKind Kind = MediaKind.File;
        // An item in the Photos library, by its place in PhotoLibrary.Scan's list; -1 for anything
        // with a file of its own.
        public int LibraryIndex = -1;
        // The picture's or video's size in pixels, where the library says.
        public int Width;
        public int Height;
        public double Seconds;
        // A panorama's span and height in degrees where its metadata said (a photo sphere's
        // GPano crop); 0 to take them from its shape.
        public float PanoramaSpan;
        public float PanoramaHeight;

        public bool NeedsDownload => Url == null && DriveId != null;

        public bool IsLibrary => LibraryIndex >= 0;

        public bool IsSpatial => Kind == MediaKind.SpatialPhoto || Kind == MediaKind.SpatialVideo;

        public bool IsSpatialPhoto => Kind == MediaKind.SpatialPhoto;

        public bool IsSpatialVideo => Kind == MediaKind.SpatialVideo;

        // A still of any kind: nothing to play, pause or seek.
        public bool IsPicture => Kind == MediaKind.Photo || Kind == MediaKind.Still360 || Kind == MediaKind.Panorama ||
                                 Kind == MediaKind.SpatialPhoto;

        public bool IsVideo => !IsPicture;

        // The picture's shape, for the aspect-based kinds.
        public float Aspect => Width > 0 && Height > 0 ? (float)Width / Height : 0f;
    }

    // Finds the media to offer: the videos bundled with the app, the photos and videos the user
    // copied or imported into the Media folder (or the older Videos folder), Google Drive links
    // listed in videos.txt in either, and, on an iPhone, the photos and videos already in the
    // user's Photos library.
    //   Android: /storage/emulated/0/Android/data/com.wemiller.afterglow/files/Media
    //            (adb push beach_360.mp4 there; no storage permission needed)
    //   iPhone:  the app's Documents/Media, which Finder (the phone's Files tab), the Files app and
    //            the browser's Import button (FilePicker) can copy into, since the app shares its
    //            Documents folder
    // videos.txt takes one link per line, optionally followed by a name, whose tags say the format
    // (see VideoFormat.FromFileName). Lines starting with # are skipped. A downloaded video is kept
    // in the cache, named by its Drive id, so it only downloads once.
    public static class VideoLibrary
    {
        public const string ListFileName = "videos.txt";
        static readonly string[] k_Extensions = { ".mp4", ".mov", ".m4v", ".webm" };
        static readonly string[] k_ImageExtensions = { ".jpg", ".jpeg", ".png", ".heic", ".heif" };

        // Where the Files picker imports to and what the user copies into: Media, and the older
        // Videos folder, which is still read.
        public static string MediaFolder => Path.Combine(Application.persistentDataPath, "Media");
        public static string VideoFolder => Path.Combine(Application.persistentDataPath, "Videos");
        public static string CacheFolder => Path.Combine(Application.temporaryCachePath, "DriveVideos");

        // placeholders are the repository's own bundled videos; count is how many bundled videos were
        // found; album picks one of PhotoLibrary.Albums in place of the whole library.
        public static List<VideoEntry> Find(IEnumerable<string> placeholders, out int count, int album = PhotoLibrary.k_WholeLibrary)
        {
            var entries = new List<VideoEntry>();
            var bundled = OrderBundled(StreamingAssetsFiles(), placeholders);
            count = bundled.Count;
            foreach (var name in bundled)
            {
                entries.Add(new VideoEntry
                {
                    Title = Path.GetFileNameWithoutExtension(name),
                    Format = VideoFormat.FromFileName(name),
                    Url = Path.Combine(Application.streamingAssetsPath, name),
                });
            }

            foreach (var folder in new[] { MediaFolder, VideoFolder })
            {
                try
                {
                    // Made even when empty, so there's somewhere visible to copy media into.
                    Directory.CreateDirectory(folder);
                    var files = new List<string>(Directory.GetFiles(folder));
                    files.Sort(StringComparer.OrdinalIgnoreCase);
                    foreach (var file in files)
                    {
                        if (IsVideo(file))
                        {
                            // The file's own spherical-video boxes first, then the tags in its name.
                            var fromBoxes = MediaMetadata.TryReadVideoFormat(file, out var boxed);
                            if (fromBoxes)
                                Debug.Log($"[Video] {Path.GetFileName(file)} says it is {boxed} in its metadata");
                            entries.Add(new VideoEntry
                            {
                                Title = Path.GetFileNameWithoutExtension(file),
                                Format = fromBoxes ? boxed : VideoFormat.FromFileName(file),
                                Url = file,
                            });
                        }
                        else if (IsImage(file))
                        {
                            PhotoLibrary.TryGetFileImageSize(file, out var width, out var height);
                            MediaMetadata.PhotoSphere? sphere = null;
                            if (IsJpeg(file) && MediaMetadata.TryReadPhotoSphere(file, out var found))
                            {
                                sphere = found;
                                Debug.Log($"[Video] {Path.GetFileName(file)} is a photo sphere: {found.DegreesWide:F0} x {found.DegreesTall:F0} degrees");
                            }
                            entries.Add(FileImageEntry(file, width, height, sphere));
                        }
                    }

                    var list = Path.Combine(folder, ListFileName);
                    if (File.Exists(list))
                        entries.AddRange(ParseList(File.ReadAllLines(list)));
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    Debug.LogWarning($"[Video] Couldn't read {folder}: {e.Message}");
                }
            }

            entries.AddRange(LibraryEntries(album));
            return entries;
        }

        // What the home screen's Files section lists: the videos the user copied in or linked, which
        // is everything but the first bundledCount entries (the repository's own clips) and the Photos
        // library's items. Pure, for testing.
        public static List<VideoEntry> FilesOnly(List<VideoEntry> entries, int bundledCount)
        {
            var files = new List<VideoEntry>();
            for (var i = bundledCount; i < entries.Count; i++)
            {
                if (!entries[i].IsLibrary)
                    files.Add(entries[i]);
            }
            return files;
        }

        // What an album's page lists: the library's items alone, since an album is a view of the
        // library and the bundled clips and the Media folder aren't in it. Pure, for testing.
        public static List<VideoEntry> LibraryOnly(List<VideoEntry> entries) => entries.FindAll(entry => entry.IsLibrary);

        // A picture whose sides are this close to 2:1 is taken for a 360 still.
        public const float k_Still360Tolerance = 0.03f;
        // A picture at least this wide for its height is a panorama even when the library doesn't
        // say so: an imported one carries no subtype, only its shape.
        public const float k_PanoramaAspect = 2.4f;
        // How tall a panorama's cylinder looks, in degrees: about the phone camera's view across
        // its short side, which is what a panorama is swept with. Its width follows from the
        // picture's shape (PanoramaDegrees).
        public const float k_PanoramaHeightDegrees = 60f;

        // The photos and videos in the Photos library, which need no copying in: the phone in the
        // viewer is the one that took them. Empty everywhere but an iPhone, and empty until the
        // user has allowed the library.
        static IEnumerable<VideoEntry> LibraryEntries(int album)
        {
            if (!PhotoLibrary.Supported)
                yield break;
            foreach (var item in PhotoLibrary.Scan(album))
                yield return LibraryEntry(item);
        }

        // An album's row in the picker: its name and what it holds.
        public static string AlbumLabel(string title, int count) =>
            count == 1 ? $"{title} · 1 item" : $"{title} · {count:N0} items";

        // An entry for one library item, named by when it was taken.
        public static VideoEntry LibraryEntry(PhotoLibrary.Item item)
        {
            var kind = Classify(item.IsVideo, item.IsSpatial, item.IsPanorama, item.Width, item.Height);
            return new VideoEntry
            {
                Title = $"{Describe(kind)}, {item.Title}",
                Format = DefaultFormat(kind, item.Width, item.Height),
                Kind = kind,
                LibraryIndex = item.Index,
                Width = item.Width,
                Height = item.Height,
                Seconds = item.Seconds,
            };
        }

        // What a library item is, from what the library says and the picture's shape. Pure, for
        // testing.
        public static MediaKind Classify(bool isVideo, bool isSpatial, bool isPanorama, int width, int height)
        {
            if (isSpatial)
                return isVideo ? MediaKind.SpatialVideo : MediaKind.SpatialPhoto;
            if (isVideo)
                return MediaKind.LibraryVideo;
            var aspect = width > 0 && height > 0 ? (float)width / height : 0f;
            if (isPanorama || aspect >= k_PanoramaAspect)
                return MediaKind.Panorama;
            if (Mathf.Abs(aspect - 2f) <= 2f * k_Still360Tolerance)
                return MediaKind.Still360;
            return MediaKind.Photo;
        }

        // How a kind is drawn unless the user changes it: a 2:1 video is taken for 360, any other
        // for a film on the screen.
        public static VideoFormat DefaultFormat(MediaKind kind, int width, int height)
        {
            var aspect = width > 0 && height > 0 ? (float)width / height : 0f;
            switch (kind)
            {
                case MediaKind.Still360:
                    return VideoFormat.Mono360;
                case MediaKind.SpatialPhoto:
                case MediaKind.SpatialVideo:
                    return VideoFormat.Stereo3D;
                case MediaKind.LibraryVideo:
                    return Mathf.Abs(aspect - 2f) <= 2f * k_Still360Tolerance
                        ? VideoFormat.Mono360
                        : new VideoFormat(Projection.Flat, StereoLayout.Mono);
                default:
                    return new VideoFormat(Projection.Flat, StereoLayout.Mono);
            }
        }

        public static string Describe(MediaKind kind) => kind switch
        {
            MediaKind.Photo => "Photo",
            MediaKind.Still360 => "360 still",
            MediaKind.Panorama => "Panorama",
            MediaKind.LibraryVideo => "Video",
            MediaKind.SpatialPhoto => "Spatial photo",
            MediaKind.SpatialVideo => "Spatial video",
            MediaKind.Drive => "Drive video",
            _ => "Video file",
        };

        // How far round a panorama's cylinder goes, in degrees, from the picture's shape: its
        // width in units of its height, each as tall as k_PanoramaHeightDegrees. An iPhone's
        // panorama runs to about 240 degrees; nothing goes past a full turn.
        public static float PanoramaDegrees(int width, int height, float heightDegrees = k_PanoramaHeightDegrees)
        {
            if (width <= 0 || height <= 0)
                return 180f;
            return Mathf.Clamp((float)width / height * heightDegrees, heightDegrees, 360f);
        }

        // An entry's panorama span and height: what its metadata said, else from its shape (or
        // the size given, the opened picture's, when that's known better than the entry's).
        public static float PanoramaDegrees(VideoEntry entry, int width = 0, int height = 0)
        {
            if (entry.PanoramaSpan > 0f)
                return entry.PanoramaSpan;
            return PanoramaDegrees(width > 0 ? width : entry.Width, height > 0 ? height : entry.Height, PanoramaHeightDegrees(entry));
        }

        public static float PanoramaHeightDegrees(VideoEntry entry) =>
            entry.PanoramaHeight > 0f ? entry.PanoramaHeight : k_PanoramaHeightDegrees;

        // Whether an entry belongs under a filter. 360 means anything wrapped round the viewer:
        // the stills, and the videos whose format isn't a flat screen.
        public static bool Matches(VideoEntry entry, MediaFilter filter) => filter switch
        {
            MediaFilter.Spatial => entry.IsSpatial,
            MediaFilter.Panoramas => entry.Kind == MediaKind.Panorama,
            MediaFilter.Still360 => entry.Kind == MediaKind.Still360 ||
                                    (entry.IsVideo && entry.Format.Projection != Projection.Flat),
            MediaFilter.Videos => entry.IsVideo,
            _ => true,
        };

        public static List<VideoEntry> Filter(IEnumerable<VideoEntry> entries, MediaFilter filter)
        {
            var found = new List<VideoEntry>();
            foreach (var entry in entries)
            {
                if (Matches(entry, filter))
                    found.Add(entry);
            }
            return found;
        }

        public static bool IsVideo(string path) => Array.IndexOf(k_Extensions, Path.GetExtension(path).ToLowerInvariant()) >= 0;

        public static bool IsImage(string path) => Array.IndexOf(k_ImageExtensions, Path.GetExtension(path).ToLowerInvariant()) >= 0;

        public static bool IsJpeg(string path)
        {
            var extension = Path.GetExtension(path).ToLowerInvariant();
            return extension == ".jpg" || extension == ".jpeg";
        }

        // A picture file: its kind from its shape when the size is known (iOS reads the header),
        // else a photo until it's opened, when the player sizes and sorts it. A spatial HEIC among
        // them is found when it's opened, from the pair inside it. Pure, for testing.
        public static VideoEntry FileImageEntry(string path, int width, int height) => FileImageEntry(path, width, height, null);

        // The same with what the file's GPano said, which wins over its shape: the whole sphere
        // is a 360 still, anything less a panorama of that span and height.
        public static VideoEntry FileImageEntry(string path, int width, int height, MediaMetadata.PhotoSphere? sphere)
        {
            var kind = sphere == null ? Classify(false, false, false, width, height)
                : sphere.Value.IsFull ? MediaKind.Still360 : MediaKind.Panorama;
            var entry = new VideoEntry
            {
                Title = Path.GetFileNameWithoutExtension(path),
                Format = DefaultFormat(kind, width, height),
                Url = path,
                Kind = kind,
                Width = width,
                Height = height,
            };
            if (sphere != null && kind == MediaKind.Panorama)
            {
                entry.PanoramaSpan = sphere.Value.DegreesWide;
                entry.PanoramaHeight = sphere.Value.DegreesTall;
            }
            return entry;
        }

        // The video files among present: your own first, by name, then the placeholders that are there,
        // in their order. Pure, for testing.
        public static List<string> OrderBundled(IEnumerable<string> present, IEnumerable<string> placeholders)
        {
            var own = new List<string>();
            foreach (var name in present)
            {
                if (IsVideo(name))
                    own.Add(name);
            }
            var found = new List<string>();
            foreach (var name in placeholders)
            {
                var index = own.FindIndex(file => string.Equals(file, name, StringComparison.OrdinalIgnoreCase));
                if (index < 0)
                    continue;
                found.Add(own[index]);
                own.RemoveAt(index);
            }
            own.Sort(StringComparer.OrdinalIgnoreCase);
            own.AddRange(found);
            return own;
        }

        // The file names at the top of StreamingAssets. On Android they're inside the APK, where only
        // its AssetManager can list them.
        static IEnumerable<string> StreamingAssetsFiles()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            try
            {
                using var unityPlayer = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
                using var activity = unityPlayer.GetStatic<AndroidJavaObject>("currentActivity");
                using var assets = activity.Call<AndroidJavaObject>("getAssets");
                return assets.Call<string[]>("list", "") ?? Array.Empty<string>();
            }
            catch (AndroidJavaException e)
            {
                Debug.LogWarning($"[Video] Couldn't list the bundled videos: {e.Message}");
                return Array.Empty<string>();
            }
#else
            var folder = Application.streamingAssetsPath;
            if (!Directory.Exists(folder))
                return Array.Empty<string>();
            var names = new List<string>();
            foreach (var file in Directory.GetFiles(folder))
                names.Add(Path.GetFileName(file));
            return names;
#endif
        }

        // The Drive videos listed in videos.txt, with the ones already downloaded ready to play.
        public static List<VideoEntry> ParseList(IEnumerable<string> lines)
        {
            var entries = new List<VideoEntry>();
            foreach (var raw in lines)
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#"))
                    continue;
                var space = line.IndexOfAny(new[] { ' ', '\t' });
                var link = space < 0 ? line : line.Substring(0, space);
                var name = space < 0 ? null : line.Substring(space + 1).Trim();
                if (!DriveLink.TryGetFileId(link, out var id))
                {
                    Debug.LogWarning($"[Video] Not a Google Drive link, skipped: {link}");
                    continue;
                }

                var cached = CachedFile(id);
                var fileName = name ?? (cached != null ? Path.GetFileName(cached) : null);
                entries.Add(new VideoEntry
                {
                    Title = fileName != null ? Path.GetFileNameWithoutExtension(fileName) : $"Drive video {id.Substring(0, 6)}",
                    Format = VideoFormat.FromFileName(fileName),
                    Url = cached,
                    DriveId = id,
                    Kind = MediaKind.Drive,
                });
            }
            return entries;
        }

        // The downloaded file for a Drive id, if it's in the cache.
        public static string CachedFile(string id)
        {
            var folder = Path.Combine(CacheFolder, id);
            if (!Directory.Exists(folder))
                return null;
            var files = Directory.GetFiles(folder);
            return files.Length > 0 ? files[0] : null;
        }
    }
}
