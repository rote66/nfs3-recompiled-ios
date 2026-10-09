#import <AVFoundation/AVFoundation.h>
#include "Native.h"
#include <lib/audio.h>
#include <algorithm>
#include <mutex>
#include <nfs3hp.h>
#include <thread>
#include <cmath>
#include <memory>

namespace
{
struct NativeAudio
{
    win32::AudioDevice* owner;
    std::mutex mutex;
    AVAudioEngine* engine = nil;
    AVAudioSourceNode* source = nil;
    id configurationObserver = nil;
    std::shared_ptr<std::atomic_bool> configurationChanged;
    uint64_t generation = 0;
    unsigned graphSerial = 0;
    bool rebuildRequired = true;
    bool active = false;
};
std::mutex devicesMutex;
std::vector<NativeAudio*> devices;
bool audioEnabled = true;
std::atomic<uint64_t> audioGeneration{1};
std::once_flag audioObserversOnce;
NSArray* audioObservers;
enum class AudioFault { None, Activation, OutputRoute, EngineStart };
std::atomic<AudioFault> nextAudioFault{AudioFault::None};

bool takeAudioFault(AudioFault fault)
{
    return nextAudioFault.compare_exchange_strong(fault, AudioFault::None);
}

void observeAudioSession()
{
    std::call_once(audioObserversOnce, [] {
        NSMutableArray* observers = [NSMutableArray new];
        for (NSString* name in @[AVAudioSessionMediaServicesWereLostNotification, AVAudioSessionMediaServicesWereResetNotification, AVAudioSessionRouteChangeNotification])
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification* notification) {
                audioGeneration.fetch_add(1);
                if ([notification.name isEqualToString:AVAudioSessionRouteChangeNotification])
                    win32::platform::log("NFS3_AUDIO: route changed reason=%lu", [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedLongValue]);
                else
                    win32::platform::log("NFS3_AUDIO: media services %s", [notification.name isEqualToString:AVAudioSessionMediaServicesWereLostNotification] ? "lost" : "reset");
            }]];
        audioObservers = observers;
    });
}

bool graphCurrent(NativeAudio* state)
{
    return state->engine && !state->rebuildRequired && state->generation == audioGeneration.load() && !state->configurationChanged->load();
}

void disposeGraph(NativeAudio* state)
{
    if (state->configurationObserver) [NSNotificationCenter.defaultCenter removeObserver:state->configurationObserver];
    state->configurationObserver = nil;
    [state->engine stop];
    if (state->source) [state->engine detachNode:state->source];
    state->source = nil;
    state->engine = nil;
}

void rebuildGraph(NativeAudio* state)
{
    disposeGraph(state);
    state->generation = audioGeneration.load();
    state->configurationChanged = std::make_shared<std::atomic_bool>(false);
    state->engine = [AVAudioEngine new];
    auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:22050 channels:2];
    win32::AudioDevice* owner = state->owner;
    state->source = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL* silence, const AudioTimeStamp*, AVAudioFrameCount frames, AudioBufferList* output) {
        if (output->mNumberBuffers < 2) { *silence = YES; return noErr; }
        owner->render(static_cast<float*>(output->mBuffers[0].mData), static_cast<float*>(output->mBuffers[1].mData), frames);
        *silence = NO;
        return noErr;
    }];
    [state->engine attachNode:state->source];
    [state->engine connect:state->source to:state->engine.mainMixerNode format:format];
    auto changed = state->configurationChanged;
    state->configurationObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification object:state->engine queue:nil usingBlock:^(NSNotification*) {
        changed->store(true);
    }];
    state->rebuildRequired = false;
    ++state->graphSerial;
    win32::platform::log("NFS3_AUDIO: output graph rebuilt serial=%u generation=%llu", state->graphSerial, static_cast<unsigned long long>(state->generation));
}

bool startAudio(NativeAudio* state)
{
    NSError* error = nil;
    AVAudioSession* session = AVAudioSession.sharedInstance;
    BOOL activated;
    if (takeAudioFault(AudioFault::Activation))
    {
        activated = NO;
        error = [NSError errorWithDomain:NSOSStatusErrorDomain code:1836282486 userInfo:nil];
    }
    else
        activated = [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error] && [session setActive:YES error:&error];
    if (!activated)
    {
        state->rebuildRequired = true;
        win32::platform::log("NFS3_AUDIO: activation failed code=%ld", long(error.code));
        return false;
    }
    bool rebuilt = !graphCurrent(state);
    if (rebuilt) rebuildGraph(state);
    while (!state->engine.isRunning)
    {
        AVAudioFormat* output = [state->engine.outputNode outputFormatForBus:0];
        if (takeAudioFault(AudioFault::OutputRoute) || !output.channelCount || output.sampleRate <= 0)
        {
            win32::platform::log("NFS3_AUDIO: output route unavailable sessionRate=%.0f sessionChannels=%lu outputs=%lu", session.sampleRate, static_cast<unsigned long>(session.outputNumberOfChannels), static_cast<unsigned long>(session.currentRoute.outputs.count));
            state->rebuildRequired = true;
            if (rebuilt) return false;
            rebuildGraph(state);
            rebuilt = true;
            continue;
        }
        [state->engine stop];
        [state->engine connect:state->engine.mainMixerNode to:state->engine.outputNode format:nil];
        [state->engine prepare];
        BOOL started;
        if (takeAudioFault(AudioFault::EngineStart))
        {
            started = NO;
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:nil];
        }
        else started = [state->engine startAndReturnError:&error];
        if (!started)
        {
            state->rebuildRequired = true;
            win32::platform::log("NFS3_AUDIO: engine start failed code=%ld", long(error.code));
            if (rebuilt) return false;
            rebuildGraph(state);
            rebuilt = true;
            continue;
        }
        win32::platform::log("NFS3_AUDIO: engine resumed rate=%.0f channels=%u", output.sampleRate, unsigned(output.channelCount));
    }
    return state->engine.isRunning && graphCurrent(state);
}
}
namespace nfsios
{
bool audioDiagnostic()
{
    @autoreleasepool
    {
        nfs3hp::Application app("nfs3.exe");
        win32::AudioDevice audio;
        win32::AudioBuffer tone(&audio, &app, 16384);
        uint32_t start = tone.lock();
        for (unsigned frame = 0; frame < 4096; ++frame)
        {
            int16_t sample = std::sin(frame * 2 * M_PI * 440 / 22050) * 2000;
            app.getMemory<int16_t>(start + frame * 4) = sample;
            app.getMemory<int16_t>(start + frame * 4 + 2) = sample;
        }
        tone.unlock(16384);
        tone.play();
        auto consumedAfter = [&](win32::AudioBuffer& buffer, uint32_t start) {
            for (unsigned attempt = 0; attempt < 100; ++attempt)
            {
                if (buffer.playStart() > start) return true;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            return false;
        };
        bool consumed = audioActive(true) && consumedAfter(tone, 0);
        for (unsigned cycle = 0; consumed && cycle < 6; ++cycle)
        {
            audioActive(false);
            uint32_t paused = tone.playStart();
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            consumed = !audioRunning() && tone.playStart() == paused;
            tone.unlock(16384);
            consumed = consumed && audioActive(true) && audioRunning() && consumedAfter(tone, paused);
            if (cycle == 3)
            {
                auto state = static_cast<NativeAudio*>(audio.stream());
                [state->engine stop];
                uint32_t stopped = tone.playStart();
                tone.unlock(16384);
                consumed = consumed && !audioRunning() && audioActive(true) && consumedAfter(tone, stopped);
            }
        }
        win32::platform::log("NATIVE_AUDIO_DIAGNOSTIC: %s cursor=%u six pause/resume cycles retain buffers, stopped engine rebuilds output connection and resumes callback", consumed ? "PASS" : "NO_AUDIO_OUTPUT", tone.playStart());
        bool recovered = consumed;
        auto state = static_cast<NativeAudio*>(audio.stream());
        auto notify = [](NSString* name, id object, NSDictionary* info = nil) {
            [NSNotificationCenter.defaultCenter postNotificationName:name object:object userInfo:info];
        };
        auto resumesWithNewGraph = [&](unsigned serial, uint32_t cursor) {
            return audioActive(true) && audioRunning() && state->graphSerial > serial && consumedAfter(tone, cursor) && [state->source outputFormatForBus:0].sampleRate == 22050;
        };
        if (recovered)
        {
            unsigned serial = state->graphSerial;
            notify(AVAudioSessionMediaServicesWereLostNotification, AVAudioSession.sharedInstance);
            recovered = !audioRunning();
            audioActive(false);
            uint32_t cursor = tone.playStart();
            notify(AVAudioSessionMediaServicesWereResetNotification, AVAudioSession.sharedInstance);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            recovered = recovered && !audioRunning() && state->graphSerial == serial && tone.playStart() == cursor;
            tone.unlock(16384);
            recovered = recovered && resumesWithNewGraph(serial, cursor);
        }
        for (NSString* notification in @[AVAudioSessionMediaServicesWereResetNotification, AVAudioSessionRouteChangeNotification, AVAudioEngineConfigurationChangeNotification])
        {
            if (!recovered) break;
            unsigned serial = state->graphSerial;
            uint32_t cursor = tone.playStart();
            NSDictionary* info = [notification isEqualToString:AVAudioSessionRouteChangeNotification] ? @{AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonRouteConfigurationChange)} : nil;
            notify(notification, [notification isEqualToString:AVAudioEngineConfigurationChangeNotification] ? state->engine : AVAudioSession.sharedInstance, info);
            recovered = !audioRunning();
            tone.unlock(16384);
            recovered = recovered && resumesWithNewGraph(serial, cursor);
        }
        for (AudioFault fault : {AudioFault::Activation, AudioFault::OutputRoute, AudioFault::EngineStart})
        {
            if (!recovered) break;
            audioActive(false);
            unsigned serial = state->graphSerial;
            uint32_t cursor = tone.playStart();
            tone.unlock(16384);
            nextAudioFault = fault;
            if (fault == AudioFault::Activation)
            {
                recovered = !audioActive(true) && !audioRunning() && tone.playStart() == cursor;
                recovered = recovered && resumesWithNewGraph(serial, cursor);
            }
            else recovered = resumesWithNewGraph(serial, cursor);
        }
        for (AudioFault fault : {AudioFault::OutputRoute, AudioFault::EngineStart})
        {
            if (!recovered) break;
            audioActive(false);
            uint32_t cursor = tone.playStart();
            tone.unlock(16384);
            { std::lock_guard<std::mutex> guard(devicesMutex); state->rebuildRequired = true; }
            nextAudioFault = fault;
            recovered = !audioActive(true) && !audioRunning() && tone.playStart() == cursor;
            unsigned serial = state->graphSerial;
            recovered = recovered && resumesWithNewGraph(serial, cursor);
        }
        nextAudioFault = AudioFault::None;
        if (recovered)
        {
            win32::AudioDevice secondaryAudio;
            win32::AudioBuffer secondaryTone(&secondaryAudio, &app, 16384);
            uint32_t secondaryStart = secondaryTone.lock();
            for (unsigned frame = 0; frame < 4096; ++frame)
            {
                int16_t sample = std::sin(frame * 2 * M_PI * 440 / 22050) * 2000;
                app.getMemory<int16_t>(secondaryStart + frame * 4) = sample;
                app.getMemory<int16_t>(secondaryStart + frame * 4 + 2) = sample;
            }
            secondaryTone.play();
            audioActive(false);
            auto secondaryState = static_cast<NativeAudio*>(secondaryAudio.stream());
            unsigned serial = state->graphSerial, secondarySerial = secondaryState->graphSerial;
            uint32_t cursor = tone.playStart();
            NSError* error = nil;
            recovered = [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient mode:AVAudioSessionModeDefault options:0 error:&error];
            notify(AVAudioSessionMediaServicesWereResetNotification, AVAudioSession.sharedInstance);
            recovered = recovered && !audioRunning() && state->graphSerial == serial && secondaryState->graphSerial == secondarySerial;
            tone.unlock(16384);
            secondaryTone.unlock(16384);
            recovered = recovered && resumesWithNewGraph(serial, cursor) && secondaryState->graphSerial > secondarySerial && consumedAfter(secondaryTone, 0);
            recovered = recovered && [AVAudioSession.sharedInstance.category isEqualToString:AVAudioSessionCategoryPlayback] && [AVAudioSession.sharedInstance.mode isEqualToString:AVAudioSessionModeDefault];
        }
        win32::platform::log("NFS3_AUDIO_RECOVERY_DIAGNOSTIC: %s cursor=%u graphs=%u media-service loss/reset while backgrounded, foreground reset, route/engine changes, activation failure, stale output/start failure, fresh-graph failure/retry and two-device session-category restoration retain stereo 22050-Hz buffers and resume actual callbacks", recovered ? "PASS" : "FAIL", tone.playStart(), state->graphSerial);
        return recovered;
    }
}
bool audioActive(bool active)
{
    std::lock_guard<std::mutex> guard(devicesMutex);
    audioEnabled = active;
    bool resumed = true;
    for (auto state : devices)
    {
        { std::lock_guard<std::mutex> audioGuard(state->mutex); state->active = false; }
        if (active)
        {
            bool started = startAudio(state);
            { std::lock_guard<std::mutex> audioGuard(state->mutex); state->active = started; }
            resumed = resumed && started;
        }
        else [state->engine pause];
    }
    return resumed;
}
bool audioRunning()
{
    std::lock_guard<std::mutex> guard(devicesMutex);
    return audioEnabled && std::all_of(devices.begin(), devices.end(), [](NativeAudio* state) {
        std::lock_guard<std::mutex> audioGuard(state->mutex);
        return state->active && state->engine.isRunning && graphCurrent(state);
    });
}
}
namespace win32
{
AudioDevice::AudioDevice() : m_stream(new NativeAudio)
{
    @autoreleasepool
    {
        auto state = static_cast<NativeAudio*>(m_stream);
        state->owner = this;
        observeAudioSession();
        std::lock_guard<std::mutex> guard(devicesMutex);
        state->active = audioEnabled && startAudio(state);
        devices.push_back(state);
    }
}
AudioDevice::~AudioDevice()
{
    auto state = static_cast<NativeAudio*>(m_stream);
    { std::lock_guard<std::mutex> guard(devicesMutex); devices.erase(std::remove(devices.begin(), devices.end(), state), devices.end()); }
    disposeGraph(state);
    delete state;
}
void AudioDevice::play(AudioBuffer* buffer)
{
    std::lock_guard<std::mutex> guard(static_cast<NativeAudio*>(m_stream)->mutex);
    if (std::find(m_playingBuffers.begin(), m_playingBuffers.end(), buffer) == m_playingBuffers.end()) m_playingBuffers.push_back(buffer);
}
void AudioDevice::stop(AudioBuffer* buffer)
{
    std::lock_guard<std::mutex> guard(static_cast<NativeAudio*>(m_stream)->mutex);
    m_playingBuffers.erase(std::remove(m_playingBuffers.begin(), m_playingBuffers.end(), buffer), m_playingBuffers.end());
}
void AudioDevice::render(float* left, float* right, unsigned frames)
{
    auto state = static_cast<NativeAudio*>(m_stream);
    std::lock_guard<std::mutex> guard(state->mutex);
    std::fill(left, left + frames, 0);
    std::fill(right, right + frames, 0);
    if (!state->active) return;
    for (auto buffer : m_playingBuffers)
    {
        uint32_t start = buffer->m_playStart;
        unsigned count = std::min(frames, (buffer->m_playStop.load() - start) / 4);
        for (unsigned index = 0; index < count; ++index)
        {
            unsigned offset = ((start + index * 4) % buffer->m_bufferSize) / 2;
            left[index] += buffer->m_buffer[offset] / 32768.0f;
            right[index] += buffer->m_buffer[(offset + 1) % (buffer->m_bufferSize / 2)] / 32768.0f;
        }
        buffer->m_playStart = start + count * 4;
    }
    for (unsigned index = 0; index < frames; ++index)
    {
        left[index] = std::clamp(left[index], -1.0f, 1.0f);
        right[index] = std::clamp(right[index], -1.0f, 1.0f);
    }
}
AudioBuffer::AudioBuffer(AudioDevice* device, WinApplication* app, x86::reg32 size)
    : m_device(device), m_bufferSize(size ? size : 16384), m_memmap(new MemMap(m_bufferSize)),
      m_bufferMap(new MemMap(m_bufferSize)), m_buffer(&app->getMemory<x86::sreg16>(m_memmap->getBlockStart())),
      m_playStart(0), m_playStop(0), m_primary(size == 0) {}
AudioBuffer::~AudioBuffer() { stop(); delete m_bufferMap; delete m_memmap; }
x86::reg32 AudioBuffer::bufferSize() const { return m_bufferSize; }
void AudioBuffer::play() { m_device->play(this); }
void AudioBuffer::stop()
{
    std::lock_guard<std::mutex> guard(devicesMutex);
    if (std::any_of(devices.begin(), devices.end(), [this](NativeAudio* state) { return state->owner == m_device; }))
        m_device->stop(this);
}
x86::reg32 AudioBuffer::lock() { return m_memmap->getBlockStart(); }
void AudioBuffer::unlock(x86::reg32 written)
{
    std::lock_guard<std::mutex> guard(static_cast<NativeAudio*>(m_device->stream())->mutex);
    m_playStop.fetch_add(written);
}
}
