// The user's Photos library, for the media browser: every photo and video, newest first, with
// what each one is (a video, a spatial pair, a panorama), its size, a thumbnail on request, and
// the pictures themselves when one is opened. PhotoLibrary.cs is the C# side.
//
// Three kinds of picture come out of here. A plain photo, a panorama or a 360 still is one picture,
// decoded through ImageIO with its orientation applied and capped at a size the headset can hold
// (a 48 MP photo as BGRA is 190 MB, and nothing in a viewer needs more than a few thousand pixels
// across). A spatial photo is one HEIC holding two pictures, one per eye, tied together by a
// stereo pair group in the file's metadata; a plain decode gives the "hero" eye and silently
// throws the other away, so the pair is found through ImageIO's group metadata and each eye is
// drawn into its own buffer. A spatial video is an MV-HEVC file whose two views are layers of one
// track, decoded in AfterglowSpatialVideo.mm, which opens it by its index in this file's scan; an
// ordinary video from the library is handed to Unity's player as a file path.
//
// Everything that reads a file is asynchronous, with C# polling, because a picture is opened by a
// pinch while the headset is drawing: a synchronous library fetch would hold up a frame, which in
// a viewer is a visible jolt rather than a pause.

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <atomic>
#include <mutex>
#include <unordered_map>

namespace
{
    // One picture, as the bytes Unity uploads: tightly packed BGRA rows starting at the bottom.
    struct Picture
    {
        void *bytes = nullptr;
        int width = 0;
        int height = 0;

        void Release()
        {
            free(bytes);
            bytes = nullptr;
            width = height = 0;
        }
    };

    enum LoadState
    {
        LoadStateIdle = 0,
        LoadStateLoading = 1,
        LoadStateReady = 2,
        LoadStateFailed = 3,
    };

    // What an item is, as bits C# reads.
    enum ItemKind
    {
        ItemKindVideo = 1,
        ItemKindSpatial = 2,
        ItemKindPanorama = 4,
    };

    PHFetchResult<PHAsset *> *g_Assets = nil;
    PHCachingImageManager *g_Thumbnails = nil;

    // The opened picture(s): one for a plain photo, two for a spatial one. Written on a library
    // queue and read by Unity's main thread, so the state is atomic rather than guarded: the
    // buffers are only published by setting it to Ready, after they are complete.
    Picture g_Eyes[2] = {};
    std::atomic<int> g_State{LoadStateIdle};
    // Which request the buffers belong to, so a picture opened while another is still loading
    // doesn't show the older one.
    std::atomic<int> g_Request{0};
    NSString *g_Error = nil;

    // Thumbnails in flight and delivered, by request number, until C# takes or drops them.
    struct Thumbnail
    {
        int state = LoadStateLoading;
        Picture picture;
    };
    std::mutex g_ThumbnailLock;
    std::unordered_map<int, Thumbnail> g_ThumbnailsByRequest;
    std::atomic<int> g_ThumbnailRequest{0};

    // A library video's file, fetched for Unity's player.
    std::mutex g_VideoLock;
    std::unordered_map<int, std::pair<int, NSString *>> g_VideoPaths;
    std::atomic<int> g_VideoRequest{0};

    // Draws a CGImage into a tightly packed BGRA buffer, which is what Unity's BGRA32 expects.
    bool CopyImage(CGImageRef image, Picture &picture)
    {
        if (image == nullptr)
            return false;
        const size_t width = CGImageGetWidth(image);
        const size_t height = CGImageGetHeight(image);
        if (width == 0 || height == 0)
            return false;

        const size_t stride = width * 4;
        void *bytes = malloc(stride * height);
        if (bytes == nullptr)
            return false;

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        // Unity's textures start at the bottom row and CGImage at the top, so the context is
        // flipped rather than the rows being swapped afterwards.
        CGContextRef context = CGBitmapContextCreate(
            bytes, width, height, 8, stride, space,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        if (context == nullptr)
        {
            free(bytes);
            return false;
        }
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);

        picture.bytes = bytes;
        picture.width = (int)width;
        picture.height = (int)height;
        return true;
    }

    // A UIImage as Photos hands thumbnails out, drawn the way up its orientation says.
    bool CopyUIImage(UIImage *image, Picture &picture)
    {
        if (image == nil || image.size.width < 1 || image.size.height < 1)
            return false;
        if (image.imageOrientation == UIImageOrientationUp)
            return CopyImage(image.CGImage, picture);
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
        UIImage *upright = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_) {
            [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
        }];
        return CopyImage(upright.CGImage, picture);
    }

    // The indexes of the left and right pictures in a stereo pair HEIC. Spatial photos describe the
    // pairing in a group rather than by position, so the order is read rather than assumed; a file
    // with two pictures and no group falls back on the first two, which is how side-by-side stereo
    // HEICs from other cameras are laid out.
    bool FindStereoPair(CGImageSourceRef source, size_t &left, size_t &right)
    {
        left = 0;
        right = 1;
        bool found = false;

        // The group keys are weak-linked symbols that arrived in iOS 17, and this app still builds
        // for iOS 14, so reading them on an older phone would crash rather than miss.
        if (@available(iOS 17.0, *))
        {
            NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyProperties(source, nullptr);
            NSArray *groups = properties[(__bridge NSString *)kCGImagePropertyGroups];
            for (NSDictionary *group in groups)
            {
                if (![group isKindOfClass:NSDictionary.class])
                    continue;
                id type = group[(__bridge NSString *)kCGImagePropertyGroupType];
                if (![type isEqual:(__bridge NSString *)kCGImagePropertyGroupTypeStereoPair])
                    continue;
                NSNumber *leftIndex = group[(__bridge NSString *)kCGImagePropertyGroupImageIndexLeft];
                NSNumber *rightIndex = group[(__bridge NSString *)kCGImagePropertyGroupImageIndexRight];
                if (leftIndex == nil || rightIndex == nil)
                    continue;
                left = leftIndex.unsignedLongValue;
                right = rightIndex.unsignedLongValue;
                found = true;
                break;
            }
        }

        const size_t count = CGImageSourceGetCount(source);
        if (!found && count < 2)
            return false;
        return left < count && right < count;
    }

    void ReleaseEyes()
    {
        g_Eyes[0].Release();
        g_Eyes[1].Release();
    }

    void Fail(NSString *why)
    {
        ReleaseEyes();
        g_Error = why;
        g_State = LoadStateFailed;
        NSLog(@"[Photos] %@", why);
    }

    PHAsset *AssetAt(int index)
    {
        if (g_Assets == nil || index < 0 || index >= (int)g_Assets.count)
            return nil;
        return g_Assets[index];
    }

    // Starts a request for an asset's file data. Both kinds of open go through here.
    int BeginOpen(PHAsset *asset, void (^handler)(NSData *data, int request))
    {
        const int request = g_Request.fetch_add(1) + 1;
        ReleaseEyes();
        g_Error = nil;
        g_State = LoadStateLoading;

        PHImageRequestOptions *options = [PHImageRequestOptions new];
        // The original file, not a rendition: a rendition is one flattened picture and loses the pair.
        options.version = PHImageRequestOptionsVersionCurrent;
        options.networkAccessAllowed = YES;
        options.synchronous = NO;
        [PHImageManager.defaultManager requestImageDataAndOrientationForAsset:asset options:options
            resultHandler:^(NSData *data, NSString *dataUTI, CGImagePropertyOrientation orientation, NSDictionary *info) {
                // A newer request has started, so this one's picture is no longer wanted.
                if (g_Request.load() != request)
                    return;
                if (data == nil)
                {
                    Fail(@"Photos returned no data for the picture");
                    return;
                }
                handler(data, request);
            }];
        return request;
    }
}

// 0 denied or restricted, 1 granted, 2 asking (the dialog is up; poll again).
extern "C" int Afterglow_SpatialAuthorize()
{
    const PHAuthorizationStatus status =
        [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    switch (status)
    {
        case PHAuthorizationStatusAuthorized:
        case PHAuthorizationStatusLimited:
            return 1;
        case PHAuthorizationStatusNotDetermined:
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus _) {}];
            return 2;
        default:
            return 0;
    }
}

// Lists every photo and video in the library, newest first, and returns how many there are, or
// -1 if the library can't be read yet. The list is lazy on Photos' side, so a library of
// thousands costs nothing until its items are asked for.
extern "C" int Afterglow_LibraryScan()
{
    if (Afterglow_SpatialAuthorize() != 1)
        return -1;
    PHFetchOptions *options = [PHFetchOptions new];
    options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d OR mediaType == %d",
                         (int)PHAssetMediaTypeImage, (int)PHAssetMediaTypeVideo];
    options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    g_Assets = [PHAsset fetchAssetsWithOptions:options];
    if (g_Thumbnails == nil)
        g_Thumbnails = [PHCachingImageManager new];
    NSLog(@"[Photos] %lu photos and videos in the library", (unsigned long)g_Assets.count);
    return (int)g_Assets.count;
}

// One scanned item, for the sibling plugin that opens the spatial videos: the scan and its indexes
// live here, so a video is opened by its place in the same list the photos are.
extern "C" PHAsset *Afterglow_SpatialAssetAt(int index)
{
    return AssetAt(index);
}

// Describes one item: its kind (ItemKind bits), its pixel size, how long it runs if it's a video,
// and a title for the list.
extern "C" int Afterglow_LibraryItem(int index, char *title, int titleLength, int *kind, int *width, int *height, double *seconds)
{
    PHAsset *asset = AssetAt(index);
    if (asset == nil)
        return 0;
    int bits = 0;
    if (asset.mediaType == PHAssetMediaTypeVideo)
        bits |= ItemKindVideo;
    if (asset.mediaSubtypes & PHAssetMediaSubtypePhotoPanorama)
        bits |= ItemKindPanorama;
    // Spatial media is marked by a subtype rather than being its own media type; the constant is
    // newer than this app's deployment target.
    if (@available(iOS 17.0, *))
    {
        if (asset.mediaSubtypes & PHAssetMediaSubtypeSpatialMedia)
            bits |= ItemKindSpatial;
    }
    if (kind != nullptr)
        *kind = bits;
    if (width != nullptr)
        *width = (int)asset.pixelWidth;
    if (height != nullptr)
        *height = (int)asset.pixelHeight;
    if (seconds != nullptr)
        *seconds = asset.duration;
    if (title != nullptr && titleLength > 0)
    {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"d MMM yyyy, HH:mm";
        NSString *when = asset.creationDate != nil ? [formatter stringFromDate:asset.creationDate] : @"Unknown date";
        strlcpy(title, when.UTF8String, (size_t)titleLength);
    }
    return 1;
}

// Asks for a thumbnail at most `pixels` across, and returns the request to poll with, or 0.
extern "C" int Afterglow_LibraryRequestThumbnail(int index, int pixels)
{
    PHAsset *asset = AssetAt(index);
    if (asset == nil || g_Thumbnails == nil || pixels <= 0)
        return 0;
    const int request = g_ThumbnailRequest.fetch_add(1) + 1;
    {
        std::lock_guard<std::mutex> lock(g_ThumbnailLock);
        g_ThumbnailsByRequest[request] = Thumbnail();
    }
    PHImageRequestOptions *options = [PHImageRequestOptions new];
    // One answer, not a blurry one followed by a sharp one, so a request is a request.
    options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    options.resizeMode = PHImageRequestOptionsResizeModeFast;
    options.networkAccessAllowed = YES;
    options.synchronous = NO;
    [g_Thumbnails requestImageForAsset:asset targetSize:CGSizeMake(pixels, pixels) contentMode:PHImageContentModeAspectFit
        options:options resultHandler:^(UIImage *image, NSDictionary *info) {
            Picture picture;
            const bool ok = CopyUIImage(image, picture);
            std::lock_guard<std::mutex> lock(g_ThumbnailLock);
            auto found = g_ThumbnailsByRequest.find(request);
            // Dropped meanwhile: the page it was for has gone.
            if (found == g_ThumbnailsByRequest.end())
            {
                picture.Release();
                return;
            }
            found->second.picture = picture;
            found->second.state = ok ? LoadStateReady : LoadStateFailed;
        }];
    return request;
}

// A thumbnail's pixels once they're in: 1 and the buffer, 0 while loading, -1 if it failed or was
// never asked for. The buffer belongs to the plugin until the request is released.
extern "C" int Afterglow_LibraryThumbnail(int request, void **bytes, int *width, int *height)
{
    std::lock_guard<std::mutex> lock(g_ThumbnailLock);
    auto found = g_ThumbnailsByRequest.find(request);
    if (found == g_ThumbnailsByRequest.end() || found->second.state == LoadStateFailed)
        return -1;
    if (found->second.state != LoadStateReady)
        return 0;
    if (bytes != nullptr)
        *bytes = found->second.picture.bytes;
    if (width != nullptr)
        *width = found->second.picture.width;
    if (height != nullptr)
        *height = found->second.picture.height;
    return 1;
}

extern "C" void Afterglow_LibraryReleaseThumbnail(int request)
{
    std::lock_guard<std::mutex> lock(g_ThumbnailLock);
    auto found = g_ThumbnailsByRequest.find(request);
    if (found == g_ThumbnailsByRequest.end())
        return;
    found->second.picture.Release();
    g_ThumbnailsByRequest.erase(found);
}

namespace
{
    // Decodes a source into g_Eyes: one picture, the way up its file says and no more than limit
    // pixels on its longer side, or both eyes if the file holds a stereo pair the library didn't
    // mark (one made elsewhere, or imported), so the player shows it in 3D. Publishes Ready, or
    // fails, for the request given.
    void DecodeSource(CGImageSourceRef source, int limit, int request)
    {
        if (source == nullptr)
        {
            Fail(@"The picture's file couldn't be read");
            return;
        }
        // A thumbnail "at most this big" is ImageIO's way of decoding at a size: with the limit at
        // or above the picture's own size it is the whole picture, turned the way the file's
        // orientation tag says, which the plain decode leaves to the caller.
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(limit),
            (__bridge NSString *)kCGImageSourceShouldCache: @NO,
        };
        size_t indexes[2] = { 0, 0 };
        int eyes = 1;
        size_t left = 0, right = 0;
        if (CGImageSourceGetCount(source) >= 2 && FindStereoPair(source, left, right) && left != right)
        {
            indexes[0] = left;
            indexes[1] = right;
            eyes = 2;
        }
        bool ok = true;
        for (int eye = 0; eye < eyes && ok; eye++)
        {
            CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, indexes[eye], (__bridge CFDictionaryRef)options);
            ok = CopyImage(image, g_Eyes[eye]);
            if (image != nullptr)
                CGImageRelease(image);
        }
        CFRelease(source);
        if (!ok)
        {
            Fail(@"The picture couldn't be decoded");
            return;
        }
        if (g_Request.load() != request)
        {
            ReleaseEyes();
            return;
        }
        NSLog(@"[Photos] Picture ready: %d x %d (limit %d)%@", g_Eyes[0].width, g_Eyes[0].height, limit,
              eyes == 2 ? @", a stereo pair" : @"");
        g_State = LoadStateReady;
    }
}

// Starts loading one picture from the library, the way up its file says and no more than
// maxPixels on its longer side. Returns the request number, or 0 if the item isn't a photo.
extern "C" int Afterglow_LibraryOpenImage(int index, int maxPixels)
{
    PHAsset *asset = AssetAt(index);
    if (asset == nil || asset.mediaType != PHAssetMediaTypeImage)
        return 0;
    const int limit = maxPixels > 0 ? maxPixels : 4096;
    return BeginOpen(asset, ^(NSData *data, int request) {
        DecodeSource(CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr), limit, request);
    });
}

// The same for a picture file of the app's own (an import, or one copied in): a JPEG, PNG or
// HEIC, including a spatial HEIC. Returns the request number, or 0 for no path.
extern "C" int Afterglow_FileOpenImage(const char *path, int maxPixels)
{
    if (path == nullptr)
        return 0;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    const int limit = maxPixels > 0 ? maxPixels : 4096;
    const int request = g_Request.fetch_add(1) + 1;
    ReleaseEyes();
    g_Error = nil;
    g_State = LoadStateLoading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (g_Request.load() != request)
            return;
        DecodeSource(CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr), limit, request);
    });
    return request;
}

// A picture file's size in pixels, the way up it's meant to be seen, from its header alone; 0 if
// it can't be read.
extern "C" int Afterglow_FileImageSize(const char *path, int *width, int *height)
{
    if (path == nullptr)
        return 0;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (source == nullptr)
        return 0;
    NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    CFRelease(source);
    NSNumber *w = properties[(__bridge NSString *)kCGImagePropertyPixelWidth];
    NSNumber *h = properties[(__bridge NSString *)kCGImagePropertyPixelHeight];
    NSNumber *orientation = properties[(__bridge NSString *)kCGImagePropertyOrientation];
    if (w == nil || h == nil)
        return 0;
    // Orientations 5 to 8 turn the picture on its side.
    const bool sideways = orientation != nil && orientation.intValue >= 5;
    if (width != nullptr)
        *width = sideways ? h.intValue : w.intValue;
    if (height != nullptr)
        *height = sideways ? w.intValue : h.intValue;
    return 1;
}

// Asks for a thumbnail of a file of the app's own, a picture or a video, at most `pixels`
// across; polled and released like the library's. 0 if it can't be asked for.
extern "C" int Afterglow_FileRequestThumbnail(const char *path, int pixels)
{
    if (path == nullptr || pixels <= 0)
        return 0;
    NSString *file = [NSString stringWithUTF8String:path];
    NSURL *url = [NSURL fileURLWithPath:file];
    const int request = g_ThumbnailRequest.fetch_add(1) + 1;
    {
        std::lock_guard<std::mutex> lock(g_ThumbnailLock);
        g_ThumbnailsByRequest[request] = Thumbnail();
    }
    void (^deliver)(CGImageRef) = ^(CGImageRef image) {
        Picture picture;
        const bool ok = CopyImage(image, picture);
        std::lock_guard<std::mutex> lock(g_ThumbnailLock);
        auto found = g_ThumbnailsByRequest.find(request);
        if (found == g_ThumbnailsByRequest.end())
        {
            picture.Release();
            return;
        }
        found->second.picture = picture;
        found->second.state = ok ? LoadStateReady : LoadStateFailed;
    };
    UTType *type = [UTType typeWithFilenameExtension:file.pathExtension];
    if (type != nil && [type conformsToType:UTTypeMovie])
    {
        // A frame a second in, which is past any black lead-in, no bigger than the cell.
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(pixels, pixels);
        [generator generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:CMTimeMake(1, 1)]]
            completionHandler:^(CMTime requested, CGImageRef image, CMTime actual, AVAssetImageGeneratorResult result, NSError *error) {
                deliver(result == AVAssetImageGeneratorSucceeded ? image : nullptr);
            }];
        return request;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
        CGImageRef image = nullptr;
        if (source != nullptr)
        {
            NSDictionary *options = @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(pixels),
                (__bridge NSString *)kCGImageSourceShouldCache: @NO,
            };
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            CFRelease(source);
        }
        deliver(image);
        if (image != nullptr)
            CGImageRelease(image);
    });
    return request;
}

// Starts loading one spatial photo's two pictures. Returns the request number, or 0 if the item
// isn't a photo.
extern "C" int Afterglow_SpatialOpenPhoto(int index)
{
    PHAsset *asset = AssetAt(index);
    if (asset == nil || asset.mediaType != PHAssetMediaTypeImage)
        return 0;
    return BeginOpen(asset, ^(NSData *data, int request) {
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        if (source == nullptr)
        {
            Fail(@"The spatial photo's file couldn't be read");
            return;
        }

        size_t left = 0, right = 0;
        if (!FindStereoPair(source, left, right))
        {
            CFRelease(source);
            Fail(@"That photo holds only one picture, so it isn't a stereo pair");
            return;
        }

        const size_t indexes[2] = { left, right };
        bool ok = true;
        for (int eye = 0; eye < 2 && ok; eye++)
        {
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, indexes[eye], nullptr);
            ok = CopyImage(image, g_Eyes[eye]);
            if (image != nullptr)
                CGImageRelease(image);
        }
        CFRelease(source);

        if (!ok)
        {
            Fail(@"A spatial photo's eye couldn't be decoded");
            return;
        }
        if (g_Request.load() != request)
        {
            ReleaseEyes();
            return;
        }
        NSLog(@"[Photos] Spatial photo ready: %d x %d per eye, pair %zu/%zu",
              g_Eyes[0].width, g_Eyes[0].height, left, right);
        g_State = LoadStateReady;
    });
}

// 0 nothing asked for, 1 loading, 2 ready, 3 failed.
extern "C" int Afterglow_SpatialPhotoState() { return g_State.load(); }

extern "C" const char *Afterglow_SpatialPhotoError()
{
    return g_Error != nil ? g_Error.UTF8String : "";
}

// One eye's pixels (eye 0 for a plain picture), as tightly packed BGRA rows starting at the
// bottom. The buffer belongs to this plugin and stays valid until the next open or close, which
// is long enough for Unity to upload it.
extern "C" int Afterglow_SpatialPhotoEye(int eye, void **bytes, int *width, int *height)
{
    if (eye < 0 || eye > 1 || g_State.load() != LoadStateReady || g_Eyes[eye].bytes == nullptr)
        return 0;
    if (bytes != nullptr)
        *bytes = g_Eyes[eye].bytes;
    if (width != nullptr)
        *width = g_Eyes[eye].width;
    if (height != nullptr)
        *height = g_Eyes[eye].height;
    return 1;
}

extern "C" void Afterglow_SpatialClosePhoto()
{
    g_Request.fetch_add(1);
    ReleaseEyes();
    g_Error = nil;
    g_State = LoadStateIdle;
}

// Asks for a library video's file, for Unity's player, which plays from a path. Returns the
// request to poll with, or 0 if the item isn't a video.
extern "C" int Afterglow_LibraryRequestVideoPath(int index)
{
    PHAsset *asset = AssetAt(index);
    if (asset == nil || asset.mediaType != PHAssetMediaTypeVideo)
        return 0;
    const int request = g_VideoRequest.fetch_add(1) + 1;
    {
        std::lock_guard<std::mutex> lock(g_VideoLock);
        g_VideoPaths[request] = { LoadStateLoading, nil };
    }
    PHVideoRequestOptions *options = [PHVideoRequestOptions new];
    options.version = PHVideoRequestOptionsVersionCurrent;
    options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    options.networkAccessAllowed = YES;
    [PHImageManager.defaultManager requestAVAssetForVideo:asset options:options
        resultHandler:^(AVAsset *avAsset, AVAudioMix *audioMix, NSDictionary *info) {
            NSString *path = nil;
            if ([avAsset isKindOfClass:AVURLAsset.class])
                path = ((AVURLAsset *)avAsset).URL.path;
            std::lock_guard<std::mutex> lock(g_VideoLock);
            auto found = g_VideoPaths.find(request);
            if (found == g_VideoPaths.end())
                return;
            found->second = { path != nil ? LoadStateReady : LoadStateFailed, path };
            if (path == nil)
                NSLog(@"[Photos] The video has no file to play (a composition, or not downloaded)");
        }];
    return request;
}

// The video's path once it's known: 1 and the path copied into the buffer, 0 while loading, -1 if
// there is none. Done with after the first 1 or -1.
extern "C" int Afterglow_LibraryVideoPath(int request, char *path, int pathLength)
{
    std::lock_guard<std::mutex> lock(g_VideoLock);
    auto found = g_VideoPaths.find(request);
    if (found == g_VideoPaths.end() || found->second.first == LoadStateFailed)
    {
        if (found != g_VideoPaths.end())
            g_VideoPaths.erase(found);
        return -1;
    }
    if (found->second.first != LoadStateReady)
        return 0;
    if (path != nullptr && pathLength > 0)
        strlcpy(path, found->second.second.UTF8String, (size_t)pathLength);
    g_VideoPaths.erase(found);
    return 1;
}
