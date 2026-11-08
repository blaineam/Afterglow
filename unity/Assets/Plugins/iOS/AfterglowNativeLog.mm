// A log line from a plugin, kept until Unity collects it (NativeLog.cs), so what the native side
// says reaches the session log beside the app's own lines. NSLog alone goes to the system log,
// which the session log never sees: a spatial video that stalled on an iCloud download, say, was
// invisible from the phone's log file. AGLog is what the plugins call; it does both.

#import <Foundation/Foundation.h>
#include <deque>
#include <mutex>
#include <string>

namespace
{
    std::mutex g_Lock;
    std::deque<std::string> g_Lines;
    // More than this waiting means nobody is collecting; the oldest go.
    const size_t k_MaxLines = 512;
}

extern "C" void Afterglow_NativeLog(const char *line)
{
    if (line == nullptr)
        return;
    std::lock_guard<std::mutex> lock(g_Lock);
    g_Lines.emplace_back(line);
    while (g_Lines.size() > k_MaxLines)
        g_Lines.pop_front();
}

// Lines waiting, so Unity can skip the frame without a buffer.
extern "C" int Afterglow_NativeLogCount()
{
    std::lock_guard<std::mutex> lock(g_Lock);
    return (int)g_Lines.size();
}

// The next waiting line, copied into the buffer: 1 and the line, 0 if none.
extern "C" int Afterglow_NativeLogTake(char *line, int lineLength)
{
    std::lock_guard<std::mutex> lock(g_Lock);
    if (g_Lines.empty())
        return 0;
    if (line != nullptr && lineLength > 0)
        strlcpy(line, g_Lines.front().c_str(), (size_t)lineLength);
    g_Lines.pop_front();
    return 1;
}

// Formats like NSLog, logs to the system, and keeps the line for Unity.
void AGLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", message);
    Afterglow_NativeLog(message.UTF8String);
}
