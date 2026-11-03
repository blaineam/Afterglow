// Spatial photos and videos from the user's Photos library. SpatialPhotos.cs is the C# side.
//
// A spatial photo is one HEIC file holding two pictures, one per eye, tied together by a stereo
// pair group in the file's metadata. A spatial video is an MV-HEVC file whose two views are
// separate layers of one track. Both are what an iPhone 15 Pro and later record, and both are
// invisible to anything that reads only the first picture or the first layer: a plain decode gives
// the "hero" eye and silently throws the other away.
//
// This file does the photos, which are self-contained: the stereo pair is found through ImageIO's
// group metadata, each eye is drawn into a BGRA buffer, and C# uploads the two buffers as
// textures. Videos need a decoder told to keep both layers and are in CardboardXRSpatialVideo.mm.
//
// Loading is asynchronous, with C# polling the state, because a photo is opened by a pinch while
// the headset is drawing: a synchronous library fetch would hold up a frame, which in a viewer is
// a visible jolt rather than a pause.

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <atomic>

namespace
{
    // One eye's picture, as the bytes Unity uploads.
    struct EyeImage
    {
        void *bytes;
        int width;
        int height;

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

    PHFetchResult<PHAsset *> *g_Assets = nil;
    EyeImage g_Eyes[2] = {};
    // Written on a library queue and read by Unity's main thread, so it is atomic rather than
    // guarded: the buffers are only published by setting this to Ready, after they are complete.
    std::atomic<int> g_State{LoadStateIdle};
    // Which request the buffers belong to, so a photo opened while another is still loading
    // doesn't show the older one's eyes.
    std::atomic<int> g_Request{0};
    NSString *g_Error = nil;

    // Draws a CGImage into a tightly packed BGRA buffer, which is what Unity's BGRA32 expects.
    bool CopyImage(CGImageRef image, EyeImage &eye)
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

        eye.bytes = bytes;
        eye.width = (int)width;
        eye.height = (int)height;
        return true;
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
        NSLog(@"[Spatial] %@", why);
    }
}

// 0 denied or restricted, 1 granted, 2 asking (the dialog is up; poll again).
extern "C" int CardboardXR_SpatialAuthorize()
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

// Finds every spatial photo and video in the library, newest first, and returns how many there
// are, or -1 if the library can't be read yet.
extern "C" int CardboardXR_SpatialScan()
{
    if (CardboardXR_SpatialAuthorize() != 1)
        return -1;

    // Spatial photos arrived with the iPhone 15 Pro on iOS 17, and the stereo pair is read through
    // ImageIO group keys that landed in the same release, so there is nothing to find before then.
    // The subtype constant is itself newer than this app's deployment target, which is why the
    // whole fetch sits behind the check rather than just the decode.
    if (@available(iOS 17.0, *))
    {
        PHFetchOptions *options = [PHFetchOptions new];
        // Spatial media is marked by a subtype rather than being its own media type, so the filter
        // is a test on that bit; it matches both the photos and the videos.
        options.predicate = [NSPredicate predicateWithFormat:@"(mediaSubtypes & %lu) != 0",
                             (unsigned long)PHAssetMediaSubtypeSpatialMedia];
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        g_Assets = [PHAsset fetchAssetsWithOptions:options];
        NSLog(@"[Spatial] %lu spatial items in the library", (unsigned long)g_Assets.count);
        return (int)g_Assets.count;
    }

    NSLog(@"[Spatial] This iOS is older than spatial photos, so there are none to list");
    return 0;
}

// Describes one item: whether it's a video, how long it runs, and a title for the list.
extern "C" int CardboardXR_SpatialItem(int index, char *title, int titleLength, int *isVideo, double *seconds)
{
    if (g_Assets == nil || index < 0 || index >= (int)g_Assets.count)
        return 0;
    PHAsset *asset = g_Assets[index];
    if (isVideo != nullptr)
        *isVideo = asset.mediaType == PHAssetMediaTypeVideo ? 1 : 0;
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

// Starts loading one spatial photo's two pictures. Returns the request number to pass back when
// collecting them, or 0 if the item can't be loaded.
extern "C" int CardboardXR_SpatialOpenPhoto(int index)
{
    if (g_Assets == nil || index < 0 || index >= (int)g_Assets.count)
        return 0;
    PHAsset *asset = g_Assets[index];
    if (asset.mediaType != PHAssetMediaTypeImage)
        return 0;

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
            // A newer request has started, so this one's pictures are no longer wanted.
            if (g_Request.load() != request)
                return;
            if (data == nil)
            {
                Fail(@"Photos returned no data for the spatial photo");
                return;
            }

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
            NSLog(@"[Spatial] Photo ready: %d x %d per eye, pair %zu/%zu",
                  g_Eyes[0].width, g_Eyes[0].height, left, right);
            g_State = LoadStateReady;
        }];
    return request;
}

// 0 nothing asked for, 1 loading, 2 ready, 3 failed.
extern "C" int CardboardXR_SpatialPhotoState() { return g_State.load(); }

extern "C" const char *CardboardXR_SpatialPhotoError()
{
    return g_Error != nil ? g_Error.UTF8String : "";
}

// One eye's pixels, as tightly packed BGRA rows starting at the bottom. The buffer belongs to this
// plugin and stays valid until the next open or close, which is long enough for Unity to upload it.
extern "C" int CardboardXR_SpatialPhotoEye(int eye, void **bytes, int *width, int *height)
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

extern "C" void CardboardXR_SpatialClosePhoto()
{
    g_Request.fetch_add(1);
    ReleaseEyes();
    g_Error = nil;
    g_State = LoadStateIdle;
}
