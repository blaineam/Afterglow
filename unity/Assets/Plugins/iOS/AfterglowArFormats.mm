// The video formats ARKit's world tracking offers, with which camera each comes from, which
// AR Foundation's configuration list leaves out: on an iPhone with an ultra-wide camera the list
// holds the same sizes and rates twice over, once per camera, and only the native format says
// which is which. The order here is ARKit's own, which is the order AR Foundation lists them in.
// Written as "index:WxH@fps:camera" per format, comma separated; camera is wide, ultrawide,
// telephoto or other.
#import <Foundation/Foundation.h>
#import <ARKit/ARKit.h>
#import <AVFoundation/AVFoundation.h>
#include <string.h>

extern "C" int Afterglow_ArVideoFormats(char *buffer, int capacity)
{
    if (buffer == NULL || capacity <= 1)
        return 0;
    buffer[0] = '\0';
    if (![ARWorldTrackingConfiguration isSupported])
        return 0;
    NSArray<ARVideoFormat *> *formats = ARWorldTrackingConfiguration.supportedVideoFormats;
    NSMutableString *text = [NSMutableString string];
    NSUInteger index = 0;
    for (ARVideoFormat *format in formats)
    {
        NSString *camera = @"other";
        if (@available(iOS 13.0, *))
        {
            AVCaptureDeviceType type = format.captureDeviceType;
            if ([type isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) camera = @"wide";
            else if ([type isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) camera = @"ultrawide";
            else if ([type isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera]) camera = @"telephoto";
        }
        [text appendFormat:@"%@%lu:%dx%d@%ld:%@", index == 0 ? @"" : @",", (unsigned long)index,
            (int)format.imageResolution.width, (int)format.imageResolution.height, (long)format.framesPerSecond, camera];
        index++;
    }
    const char *utf8 = text.UTF8String;
    size_t length = strlen(utf8);
    if (length >= (size_t)capacity)
        length = (size_t)capacity - 1;
    memcpy(buffer, utf8, length);
    buffer[length] = '\0';
    return (int)index;
}
