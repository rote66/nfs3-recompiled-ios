#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include "ForceFeedback.h"
#include "Native.h"
#include <algorithm>
#include <cmath>

@interface NFSHapticOutput : NSObject
@property(nonatomic, strong) CHHapticEngine* engine;
@property(nonatomic, strong) id<CHHapticAdvancedPatternPlayer> continuous;
@property(nonatomic) CFTimeInterval continuousUntil;
@property(nonatomic) CFTimeInterval retryTime;
@property(nonatomic) float lastIntensity;
@property(nonatomic) BOOL started;
- (void)hold:(float)intensity sharpness:(float)sharpness;
- (void)pulse:(float)intensity sharpness:(float)sharpness;
- (void)stop;
@end

@implementation NFSHapticOutput
- (instancetype)init
{
    if ((self = [super init])) _lastIntensity = -1;
    return self;
}
- (BOOL)startEngine
{
    if (!_engine || CACurrentMediaTime() < _retryTime) return NO;
    if (_started) return YES;
    NSError* error = nil;
    if (![_engine startAndReturnError:&error])
    {
        _retryTime = CACurrentMediaTime() + 1;
        win32::platform::log("NFS3_HAPTICS: engine start failed=%ld", (long)error.code);
        return NO;
    }
    _started = YES;
    return YES;
}
- (void)hold:(float)intensity sharpness:(float)sharpness
{
    if (intensity <= 0)
    {
        [_continuous stopAtTime:CHHapticTimeImmediate error:nil];
        _continuous = nil; _lastIntensity = -1; _continuousUntil = 0;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (!_continuous || now >= _continuousUntil)
    {
        if (![self startEngine]) return;
        [_continuous stopAtTime:CHHapticTimeImmediate error:nil];
        CHHapticEvent* event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness]
        ] relativeTime:0 duration:30];
        CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:nil];
        _continuous = [_engine createAdvancedPlayerWithPattern:pattern error:nil];
        _continuousUntil = now + 29; _lastIntensity = -1;
    }
    if (fabs(_lastIntensity - intensity) < 0.01) return;
    NSError* error = nil;
    [_continuous sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness relativeTime:0]
    ] atTime:CHHapticTimeImmediate error:&error];
    if (!error && _lastIntensity < 0) [_continuous startAtTime:CHHapticTimeImmediate error:&error];
    if (error) { _continuous = nil; _lastIntensity = -1; }
    else _lastIntensity = intensity;
}
- (void)pulse:(float)intensity sharpness:(float)sharpness
{
    if (![self startEngine]) return;
    CHHapticEvent* event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness]
    ] relativeTime:0];
    CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:nil];
    [[_engine createPlayerWithPattern:pattern error:nil] startAtTime:CHHapticTimeImmediate error:nil];
}
- (void)stop
{
    [self hold:0 sharpness:0];
    if (_started) { [_engine stopWithCompletionHandler:nil]; _started = NO; }
}
@end

namespace
{
bool phoneEnabled = false;
NFSHapticOutput* phoneOutput;
NFSHapticOutput* padOutputs[2];
GCController* padTargets[2];
float engineBaseline = 0;
CFTimeInterval nextEngineTick = 0;
CFTimeInterval nextPhoneInitialization = 0;
struct PhoneFeedback
{
    float hold = 0;
    float tick = 0;
    double tickInterval = 0;
};
PhoneFeedback phoneFeedback(const nfsios::ForceFeedbackFrame& frame, float turn, float baseline)
{
    PhoneFeedback result;
    if (frame.impact > 0.02) result.hold = (24 + 40 * frame.impact) / 255.f;
    if (frame.engineHz > 0 && turn > 0.2) result.hold = std::max(result.hold, (10 + 26 * std::clamp((turn - 0.2f) / 0.8f, 0.f, 1.f)) / 255.f);
    if (frame.engineHz > 0)
    {
        float revs = std::clamp(std::max((frame.engineHz - 16) / 14, baseline > 0 ? (frame.engine / baseline - 1) / 1.92f : 0), 0.f, 1.f);
        if (revs > 0) { result.tick = (18 + 22 * revs) / 255.f; result.tickInterval = 1 / std::clamp(frame.engineHz / 3.0, 4.0, 12.0); }
    }
    return result;
}
void connectEngine(NFSHapticOutput* output, CHHapticEngine* engine)
{
    output.engine = engine;
    engine.playsHapticsOnly = YES;
    engine.autoShutdownEnabled = YES;
    __weak NFSHapticOutput* weakOutput = output;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakOutput.continuous = nil; weakOutput.lastIntensity = -1; weakOutput.started = NO; });
    };
    engine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ weakOutput.continuous = nil; weakOutput.lastIntensity = -1; weakOutput.retryTime = 0; weakOutput.started = NO; });
    };
}
}

namespace nfsios
{
void setHapticsEnabled(bool enabled)
{
    phoneEnabled = enabled;
    if (!enabled) [phoneOutput stop];
}
void stopHaptics()
{
    [phoneOutput stop];
    for (auto* output : padOutputs) [output stop];
    engineBaseline = 0; nextEngineTick = 0;
}
void updateHaptics(bool playing)
{
    if (!playing || !isActive() || !inRace() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
    {
        stopHaptics();
        return;
    }
    if (phoneEnabled && !phoneOutput && CACurrentMediaTime() >= nextPhoneInitialization && CHHapticEngine.capabilitiesForHardware.supportsHaptics)
    {
        phoneOutput = [NFSHapticOutput new];
        NSError* error = nil;
        CHHapticEngine* engine = [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:&error];
        connectEngine(phoneOutput, engine);
        win32::platform::log("NFS3_HAPTICS: phone engine=%d error=%ld", engine != nil, (long)error.code);
        if (!engine) { phoneOutput = nil; nextPhoneInitialization = CACurrentMediaTime() + 1; }
    }
    auto first = forceFeedbackFrame(0);
    if (first.engine > 0) engineBaseline = engineBaseline > 0 ? std::min(engineBaseline, first.engine) : first.engine;
    else engineBaseline = 0;
    auto feedback = phoneFeedback(first, corneringForce(), engineBaseline);
    [phoneOutput hold:phoneEnabled ? feedback.hold : 0 sharpness:0.35];
    CFTimeInterval now = CACurrentMediaTime();
    if (phoneEnabled && feedback.hold == 0 && feedback.tick > 0 && now >= nextEngineTick)
    {
        [phoneOutput pulse:feedback.tick sharpness:0.65];
        nextEngineTick = now + feedback.tickInterval;
    }
    NSArray<GCController*>* controllers = GCController.controllers;
    for (unsigned slot = 0; slot < 2; ++slot)
    {
        GCController* target = slot < controllers.count ? controllers[slot] : nil;
        if (target != padTargets[slot])
        {
            [padOutputs[slot] stop]; padOutputs[slot] = nil; padTargets[slot] = target;
            if (target.haptics)
            {
                padOutputs[slot] = [NFSHapticOutput new];
                connectEngine(padOutputs[slot], [target.haptics createEngineWithLocality:GCHapticsLocalityDefault]);
            }
        }
        auto frame = slot == 0 ? first : forceFeedbackFrame(slot);
        [padOutputs[slot] hold:frame.intensity sharpness:0.4];
    }
}
void hapticsDiagnostic()
{
    ForceFeedbackFrame frame{};
    frame.road = 1;
    auto road = phoneFeedback(frame, 1, 0);
    NFS2_ASSERT(road.hold == 0 && road.tick == 0);
    frame.engine = 0.1; frame.engineHz = 12;
    NFS2_ASSERT(phoneFeedback(frame, 0, 0.1).tick == 0);
    NFS2_ASSERT(phoneFeedback(frame, 0.8, 0.1).hold > 0);
    frame.engineHz = 28;
    auto highRPM = phoneFeedback(frame, 0, 0.1);
    NFS2_ASSERT(highRPM.tick > 0 && highRPM.tickInterval >= 1.0 / 12 && highRPM.tickInterval <= 0.25);
    frame.engine = 0.3; frame.engineHz = 12;
    NFS2_ASSERT(phoneFeedback(frame, 0, 0.1).tick > 0);
    frame.impact = 0.8;
    NFS2_ASSERT(phoneFeedback(frame, 0, 0.1).hold > 0.2);
    setHapticsEnabled(true); setHapticsEnabled(false); stopHaptics();
    win32::platform::log("NFS3_HAPTICS_DIAGNOSTIC: PASS independent phone impact/turn/rev patterns, silent road-only and idle RPM, limiter ticks, separate controller output and launcher/lifecycle gating; physical vibration requires device test");
}
}
