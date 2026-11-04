// Speaking instead of typing. Dictation.cs is the C# side.
//
// In a viewer you cannot see your hands, so a keyboard you have to aim at one key at a time is
// the slowest input the app has. Speech is the fastest, and the phone already does it well.
//
// On-device only. SFSpeechRecognizer will happily send audio to Apple's servers, and recognition
// is the one place in this app where the user's own voice would leave the phone; a browser that
// quietly uploads what you say to it is not the browser this app is trying to be. So
// requiresOnDeviceRecognition is set, and where the locale cannot do it this reports unavailable
// rather than falling back to the network.
//
// A phrase at a time, push to talk. SFSpeechRecognitionTask stops on its own after about a
// minute, and holding a microphone open across a browsing session would cost battery and heat on
// a phone whose thermal budget is already what limits this app.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

// Kept in step with Dictation.State in C#.
enum DictationState
{
    DictationIdle = 0,
    DictationAsking = 1,
    DictationListening = 2,
    DictationDenied = 3,
    DictationUnavailable = 4,
    DictationFailed = 5,
};

@interface CardboardXRDictation : NSObject <SFSpeechRecognizerDelegate>
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) AVAudioEngine *engine;
// Written from the recognition callback, which arrives on its own queue, and read from Unity's
// thread. Atomic -- the default -- is what makes that safe, so these are not nonatomic.
@property (strong) NSString *text;
@property (assign) int state;
@property (assign) BOOL finished;
// Whether a tap is installed, so teardown only removes one that exists. Removing a tap that was
// never installed throws, and Unity compiles its plugins with Objective-C exceptions off, so
// there would be nothing to catch it with.
@property (nonatomic, assign) BOOL tapped;
@end

static CardboardXRDictation *g_Dictation = nil;

@implementation CardboardXRDictation

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        _text = @"";
        _state = DictationIdle;
    }
    return self;
}

- (void)fail:(NSString *)why asState:(int)state
{
    NSLog(@"[Speech] %@", why);
    self.state = state;
    [self teardown];
}

// Everything the microphone holds, let go of. Called on every exit path, so a failure halfway
// through starting does not leave the audio session active and the engine running.
- (void)teardown
{
    if (self.engine != nil)
    {
        if (self.engine.isRunning)
            [self.engine stop];
        if (self.tapped)
        {
            [self.engine.inputNode removeTapOnBus:0];
            self.tapped = NO;
        }
        self.engine = nil;
    }
    [self.request endAudio];
    self.request = nil;
    [self.task cancel];
    self.task = nil;
    // Letting the session go lets anything else on the phone have the microphone back.
    NSError *error = nil;
    [AVAudioSession.sharedInstance setActive:NO
                                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                      error:&error];
}

- (void)begin
{
    SFSpeechRecognizer *recognizer = self.recognizer;
    if (recognizer == nil || !recognizer.isAvailable)
    {
        [self fail:@"the recogniser isn't available for this locale" asState:DictationUnavailable];
        return;
    }
    if (!recognizer.supportsOnDeviceRecognition)
    {
        [self fail:@"this locale can only be recognised on Apple's servers, and this app won't "
                    "send your voice off the phone, so dictation is off"
            asState:DictationUnavailable];
        return;
    }

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    // Mixed with others and out of the speaker: the video demo may be playing, and taking the
    // session exclusively would stop it.
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeMeasurement
                      options:AVAudioSessionCategoryOptionMixWithOthers |
                              AVAudioSessionCategoryOptionDefaultToSpeaker
                        error:&error] ||
        ![session setActive:YES withOptions:0 error:&error])
    {
        [self fail:[NSString stringWithFormat:@"couldn't take the microphone: %@",
                    error.localizedDescription] asState:DictationFailed];
        return;
    }

    self.request = [SFSpeechAudioBufferRecognitionRequest new];
    self.request.shouldReportPartialResults = YES;    // so the bar fills in as you speak
    self.request.requiresOnDeviceRecognition = YES;

    self.engine = [AVAudioEngine new];
    AVAudioInputNode *input = self.engine.inputNode;
    // The input's own format. Asking for a different one here is the usual cause of a crash on
    // the first buffer, since the tap has to match what the hardware is actually giving.
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0)
    {
        [self fail:@"the microphone reported no usable format" asState:DictationFailed];
        return;
    }

    __weak CardboardXRDictation *weakSelf = self;
    [input installTapOnBus:0 bufferSize:1024 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf.request appendAudioPCMBuffer:buffer];
    }];
    self.tapped = YES;

    [self.engine prepare];
    if (![self.engine startAndReturnError:&error])
    {
        [self fail:[NSString stringWithFormat:@"the audio engine wouldn't start: %@",
                    error.localizedDescription] asState:DictationFailed];
        return;
    }

    self.text = @"";
    self.finished = NO;
    self.state = DictationListening;
    self.task = [recognizer recognitionTaskWithRequest:self.request
                                         resultHandler:^(SFSpeechRecognitionResult *result,
                                                         NSError *taskError) {
        CardboardXRDictation *me = weakSelf;
        if (me == nil)
            return;
        if (result != nil)
            me.text = result.bestTranscription.formattedString ?: @"";
        if (result.isFinal || taskError != nil)
        {
            if (taskError != nil)
                NSLog(@"[Speech] stopped: %@", taskError.localizedDescription);
            me.finished = YES;
            me.state = DictationIdle;
            // Back to the main thread: the engine and the audio session are not safe to take
            // apart from the recogniser's own queue.
            dispatch_async(dispatch_get_main_queue(), ^{ [me teardown]; });
        }
    }];
    NSLog(@"[Speech] listening, on device, %@", recognizer.locale.localeIdentifier);
}

@end

// Whether dictation could work at all: the framework is there and this locale can be recognised
// without leaving the phone.
extern "C" int CardboardXR_DictationAvailable()
{
    SFSpeechRecognizer *recognizer = [SFSpeechRecognizer new];
    if (recognizer == nil)
        return 0;
    return recognizer.supportsOnDeviceRecognition ? 1 : 0;
}

extern "C" void CardboardXR_DictationStart()
{
    if (g_Dictation == nil)
        g_Dictation = [CardboardXRDictation new];
    if (g_Dictation.state == DictationListening || g_Dictation.state == DictationAsking)
        return;

    g_Dictation.text = @"";
    g_Dictation.finished = NO;
    g_Dictation.recognizer = [SFSpeechRecognizer new];

    // Both permissions, and in this order: recognition first, because a refusal there makes the
    // microphone pointless, and asking for the microphone we would not use is worse than not
    // asking. iOS shows each prompt once ever, so a refusal is final until Settings.
    SFSpeechRecognizerAuthorizationStatus speech = SFSpeechRecognizer.authorizationStatus;
    if (speech == SFSpeechRecognizerAuthorizationStatusNotDetermined)
    {
        g_Dictation.state = DictationAsking;
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status != SFSpeechRecognizerAuthorizationStatusAuthorized)
                {
                    NSLog(@"[Speech] speech recognition not allowed");
                    g_Dictation.state = DictationDenied;
                    return;
                }
                CardboardXR_DictationStart();
            });
        }];
        return;
    }
    if (speech != SFSpeechRecognizerAuthorizationStatusAuthorized)
    {
        NSLog(@"[Speech] speech recognition is off for this app; turn it on in Settings");
        g_Dictation.state = DictationDenied;
        return;
    }

    if (@available(iOS 17.0, *))
    {
        AVAudioApplicationRecordPermission mic = AVAudioApplication.sharedInstance.recordPermission;
        if (mic == AVAudioApplicationRecordPermissionUndetermined)
        {
            g_Dictation.state = DictationAsking;
            [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted)
                    {
                        NSLog(@"[Speech] the microphone is not allowed");
                        g_Dictation.state = DictationDenied;
                        return;
                    }
                    [g_Dictation begin];
                });
            }];
            return;
        }
        if (mic != AVAudioApplicationRecordPermissionGranted)
        {
            NSLog(@"[Speech] the microphone is off for this app; turn it on in Settings");
            g_Dictation.state = DictationDenied;
            return;
        }
    }

    [g_Dictation begin];
}

extern "C" void CardboardXR_DictationStop()
{
    if (g_Dictation == nil)
        return;
    // endAudio rather than cancel: it lets the recogniser finish what it already heard, so the
    // last word of a phrase is not lost by letting go of the button.
    [g_Dictation.request endAudio];
    if (g_Dictation.engine != nil && g_Dictation.engine.isRunning)
        [g_Dictation.engine stop];
    if (g_Dictation.state == DictationListening)
        g_Dictation.state = DictationIdle;
    g_Dictation.finished = YES;
}

extern "C" int CardboardXR_DictationState()
{
    return g_Dictation != nil ? g_Dictation.state : DictationIdle;
}

// True once per phrase, cleared as it is read, so C# can commit the text exactly once.
extern "C" int CardboardXR_DictationTakeFinished()
{
    if (g_Dictation == nil || !g_Dictation.finished)
        return 0;
    g_Dictation.finished = NO;
    return 1;
}

extern "C" int CardboardXR_DictationCopyText(char *buffer, int capacity)
{
    if (g_Dictation == nil)
        return 0;
    const char *utf8 = (g_Dictation.text ?: @"").UTF8String;
    if (utf8 == NULL)
        return 0;
    const int length = (int)strlen(utf8);
    if (buffer != nullptr && capacity > 0)
    {
        const int room = length < capacity - 1 ? length : capacity - 1;
        memcpy(buffer, utf8, (size_t)room);
        buffer[room] = '\0';
    }
    return length;
}
