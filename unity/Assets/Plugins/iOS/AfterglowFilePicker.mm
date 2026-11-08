// The Files picker: iOS's document picker, opened over the app so the user can bring photos and
// videos in from anywhere the Files app reaches (iCloud Drive, other apps, a drive plugged in),
// copied into the app's own Media folder, where the browser lists them from then on. FilePicker.cs
// is the C# side.
//
// Copying rather than playing in place: a security-scoped file from another app is only readable
// while the picker's grant lasts, and would be gone from the list after a relaunch; a copy in the
// app's folder is the user's to keep, and is what Finder's Files tab and the Files app show under
// the app. The picker hands over copies in a temporary inbox (asCopy), which are moved from there.
//
// The picker is a full-screen sheet, so it's used with the phone out of the viewer, like the
// corner gear's menu.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <atomic>

// Logs to the system and to the session log through Unity (AfterglowNativeLog.mm).
void AGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

extern "C" UIViewController *UnityGetGLViewController();

@interface AfterglowFilePickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSString *folder;
@end

namespace
{
    AfterglowFilePickerDelegate *g_Delegate = nil;
    NSMutableArray<NSString *> *g_Imported = nil;
    NSLock *g_Lock = nil;
    std::atomic<bool> g_Open{false};
    // Picks since the last Take, counted so C# can say "nothing picked" apart from "no picker".
    std::atomic<int> g_Cancelled{0};

    // A path in the folder that isn't taken: the file's own name, then "name 2", "name 3"...
    NSString *FreePath(NSString *folder, NSString *name)
    {
        NSString *stem = name.stringByDeletingPathExtension;
        NSString *extension = name.pathExtension;
        NSString *candidate = [folder stringByAppendingPathComponent:name];
        for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:candidate]; n++)
        {
            NSString *numbered = [NSString stringWithFormat:@"%@ %d", stem, n];
            candidate = [folder stringByAppendingPathComponent:
                         extension.length > 0 ? [numbered stringByAppendingPathExtension:extension] : numbered];
        }
        return candidate;
    }
}

@implementation AfterglowFilePickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    g_Open = false;
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *url in urls)
    {
        NSString *destination = FreePath(self.folder, url.lastPathComponent);
        NSError *error = nil;
        // The copy the picker made is in a temporary inbox; moving it is instant. A URL that still
        // needs a security scope (an in-place pick) is copied under one instead.
        const BOOL scoped = [url startAccessingSecurityScopedResource];
        BOOL ok = [files moveItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error];
        if (!ok)
        {
            error = nil;
            ok = [files copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error];
        }
        if (scoped)
            [url stopAccessingSecurityScopedResource];
        if (!ok)
        {
            AGLog(@"[Files] Couldn't import %@: %@", url.lastPathComponent, error.localizedDescription);
            continue;
        }
        AGLog(@"[Files] Imported %@", destination.lastPathComponent);
        [g_Lock lock];
        [g_Imported addObject:destination];
        [g_Lock unlock];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    g_Open = false;
    g_Cancelled.fetch_add(1);
    AGLog(@"[Files] Picker cancelled");
}

@end

// Opens the picker for photos and videos, importing picks into the folder. 0 if it couldn't open
// (no view controller yet, or one is already up).
extern "C" int Afterglow_FilePickerPresent(const char *folder)
{
    if (folder == nullptr || g_Open.load())
        return 0;
    UIViewController *root = UnityGetGLViewController();
    if (root == nil)
        return 0;
    if (g_Lock == nil)
    {
        g_Lock = [NSLock new];
        g_Imported = [NSMutableArray new];
        g_Delegate = [AfterglowFilePickerDelegate new];
    }
    g_Delegate.folder = [NSString stringWithUTF8String:folder];
    g_Open = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeImage] asCopy:YES];
        picker.allowsMultipleSelection = YES;
        picker.delegate = g_Delegate;
        [root presentViewController:picker animated:YES completion:nil];
    });
    AGLog(@"[Files] Picker opened");
    return 1;
}

extern "C" int Afterglow_FilePickerIsOpen() { return g_Open.load() ? 1 : 0; }

// The next imported file's path: 1 and the path, 0 if none is waiting, -1 once for a cancelled pick.
extern "C" int Afterglow_FilePickerTake(char *path, int pathLength)
{
    if (g_Lock == nil)
        return 0;
    [g_Lock lock];
    NSString *next = g_Imported.count > 0 ? g_Imported.firstObject : nil;
    if (next != nil)
        [g_Imported removeObjectAtIndex:0];
    [g_Lock unlock];
    if (next != nil)
    {
        if (path != nullptr && pathLength > 0)
            strlcpy(path, next.UTF8String, (size_t)pathLength);
        return 1;
    }
    int cancelled = g_Cancelled.load();
    if (cancelled > 0 && g_Cancelled.compare_exchange_strong(cancelled, 0))
        return -1;
    return 0;
}
