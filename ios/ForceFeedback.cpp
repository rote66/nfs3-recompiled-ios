#include "ForceFeedback.h"
#include <winapi/wrapper.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

namespace nfsios
{
namespace
{
using namespace win32;
using Parameters = dinput::IDirectInputDevice::DIEFFECT;
using Envelope = dinput::IDirectInputDevice::DIENVELOPE;
using EffectInfo = dinput::IDirectInputDevice::DIEffectInfo;
constexpr HRESULT invalidParameters = 0x80070057;
constexpr HRESULT unsupportedEffect = 0x80004001;
const GUID effectInterface = {0xe7e1f7c0, 0x88d2, 0x11d0, {0x9a,0xd0,0,0xa0,0xc9,0xa0,0x6e,0x35}};
GUID effectGuid(unsigned kind) { return {0x13541c20 + kind, 0x8e33, 0x11d0, {0x9a,0xd0,0,0xa0,0xc9,0xa0,0x6e,0x35}}; }
bool supports(const GUID& guid)
{
    return guid.Data1 >= 0x13541c20 && guid.Data1 <= 0x13541c27 && guid == effectGuid(guid.Data1 - 0x13541c20);
}
uint64_t effectTime() { return platform::guestNanoseconds() / 1000; }
std::recursive_mutex feedbackMutex;
struct DeviceState
{
    uint32_t gain = 10000;
    bool actuators = true;
    bool paused = false;
    uint64_t pauseTime = 0;
};
std::map<Gamepad*, DeviceState> devices;
struct EffectState;
std::vector<EffectState*> effects;
struct EffectState : GenericResource
{
    Gamepad* device;
    unsigned kind;
    Parameters parameters;
    Envelope envelope{};
    std::array<DWORD, 2> axes{};
    std::array<LONG, 2> directions{};
    std::array<LONG, 12> payload{};
    bool enveloped = false;
    bool downloaded = false;
    bool playing = false;
    bool armed = false;
    bool triggerHeld = false;
    uint64_t triggerTime = 0;
    uint64_t startTime = 0;
    uint32_t repetitions = 1;
    EffectState(Gamepad* pad, unsigned type) : device(pad), kind(type)
    {
        memset(&parameters, 0, sizeof(parameters));
        parameters.dwSize = sizeof(parameters);
        parameters.dwGain = 10000;
        parameters.dwTriggerButton = UINT32_MAX;
    }
    ~EffectState()
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        effects.erase(std::remove(effects.begin(), effects.end(), this), effects.end());
    }
    bool running(uint64_t now)
    {
        if (!device || !playing) return false;
        const auto& state = devices.at(device);
        if (state.paused) now = state.pauseTime;
        uint64_t elapsed = now > startTime ? now - startTime : 0;
        if (elapsed < parameters.dwStartDelay) return true;
        if (parameters.dwDuration != UINT32_MAX && repetitions != UINT32_MAX &&
            elapsed - parameters.dwStartDelay >= uint64_t(parameters.dwDuration) * repetitions) playing = false;
        return playing;
    }
    float magnitude(uint64_t now)
    {
        if (!running(now) || kind == 7 || now < startTime + parameters.dwStartDelay) return 0;
        uint64_t elapsed = now - startTime - parameters.dwStartDelay;
        bool finite = parameters.dwDuration > 0 && parameters.dwDuration != UINT32_MAX;
        if (finite) elapsed %= parameters.dwDuration;
        float nominal = kind == 0 ? std::abs(float(payload[0])) : kind == 1 ?
            std::max(std::abs(float(payload[0])), std::abs(float(payload[1]))) : std::abs(float(payload[0]));
        float amplitude = kind == 0 ? nominal : kind == 1 ? std::abs(float(payload[0]) +
            (float(payload[1]) - payload[0]) * (finite ? float(elapsed) / parameters.dwDuration : 0)) :
            (nominal + std::abs(float(payload[1])));
        if (enveloped && nominal > 0)
        {
            float level = nominal;
            if (envelope.dwAttackTime && elapsed < envelope.dwAttackTime)
                level = envelope.dwAttackLevel + (nominal - envelope.dwAttackLevel) * float(elapsed) / envelope.dwAttackTime;
            if (finite && envelope.dwFadeTime && parameters.dwDuration - elapsed < envelope.dwFadeTime)
                level = envelope.dwFadeLevel + (nominal - envelope.dwFadeLevel) * float(parameters.dwDuration - elapsed) / envelope.dwFadeTime;
            amplitude *= std::max(0.f, level) / nominal;
        }
        if (kind == 0 && finite)
            amplitude *= std::max(0.f, 1.f - float(elapsed) / std::clamp(parameters.dwDuration * 0.5f, 80000.f, 400000.f));
        return std::clamp(amplitude / 10000.f * parameters.dwGain / 10000.f, 0.f, 1.f);
    }
};

class ForceEffect : public com::IUnknown
{
    static x86::reg32 vtableAddress;
    EffectState& state() { return *static_cast<EffectState*>(m_resource); }
public:
    explicit ForceEffect(EffectState* effect) : IUnknown(effectInterface) { m_vtable = vtableAddress; m_resource = effect; }
    ULONG release(WinApplication* app, x86::CPU& cpu)
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        if (m_refCount == 1) { app->freeResource(m_resource->getResourceIndex()); m_resource = nullptr; }
        return IUnknown::Release(app, cpu);
    }
    HRESULT initialize(WinApplication*, x86::CPU&, DWORD, DWORD, const GUID*) { return 0; }
    HRESULT guid(WinApplication*, x86::CPU&, GUID* output)
    {
        if (!output) return invalidParameters;
        *output = effectGuid(state().kind);
        return 0;
    }
    HRESULT setParameters(WinApplication* app, x86::CPU& cpu, const Parameters* input, DWORD flags)
    {
        if (!input || (input->dwSize != 52 && input->dwSize != 56)) return invalidParameters;
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        auto& effect = state();
        unsigned axes = flags & 0x20 ? input->cAxes : effect.parameters.cAxes;
        unsigned bytes = effect.kind == 0 ? 4 : effect.kind == 1 ? 8 : effect.kind == 7 ? axes * 24 : 16;
        if (axes > 2 || ((flags & 0x20) && axes && !input->rgdwAxes) ||
            ((flags & 0x40) && axes && !input->rglDirection) || ((flags & 4) && input->dwGain > 10000) ||
            ((flags & 0x100) && (input->cbTypeSpecificParams != bytes || !input->lpvTypeSpecificParams))) return invalidParameters;
        if (flags & 1) effect.parameters.dwDuration = input->dwDuration;
        if (flags & 2) effect.parameters.dwSamplePeriod = input->dwSamplePeriod;
        if (flags & 4) effect.parameters.dwGain = input->dwGain;
        if (flags & 8) effect.parameters.dwTriggerButton = input->dwTriggerButton;
        if (flags & 0x10) effect.parameters.dwTriggerRepeatInterval = input->dwTriggerRepeatInterval;
        if (flags & 0x20)
        {
            effect.parameters.cAxes = axes;
            if (axes) memcpy(effect.axes.data(), &app->getMemory<DWORD>(input->rgdwAxes), axes * 4);
        }
        if (flags & 0x40)
        {
            effect.parameters.dwFlags = input->dwFlags;
            if (axes) memcpy(effect.directions.data(), &app->getMemory<LONG>(input->rglDirection), axes * 4);
        }
        if (flags & 0x80)
        {
            effect.enveloped = input->lpEnvelope != 0;
            if (effect.enveloped) effect.envelope = app->getMemory<Envelope>(input->lpEnvelope);
        }
        if (flags & 0x100)
        {
            memcpy(effect.payload.data(), &app->getMemory<LONG>(input->lpvTypeSpecificParams), bytes);
            effect.parameters.cbTypeSpecificParams = bytes;
        }
        if ((flags & 0x200) && input->dwSize == 56) effect.parameters.dwStartDelay = input->dwStartDelay;
        if (!(flags & 0x80000000)) effect.downloaded = true;
        if (effect.kind == 0 && effect.armed && effect.parameters.dwDuration && effect.parameters.dwDuration != UINT32_MAX && (flags & 0x141))
        {
            effect.playing = true; effect.repetitions = 1; effect.startTime = effectTime();
        }
        return flags & 0x20000000 ? start(app, cpu, 1, 0) : 0;
    }
    HRESULT getParameters(WinApplication* app, x86::CPU&, Parameters* output, DWORD flags)
    {
        if (!output || (output->dwSize != 52 && output->dwSize != 56)) return invalidParameters;
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        const auto& effect = state();
        if (((flags & 0x60) && output->cAxes < effect.parameters.cAxes) ||
            ((flags & 0x100) && output->cbTypeSpecificParams < effect.parameters.cbTypeSpecificParams))
        {
            output->cAxes = effect.parameters.cAxes; output->cbTypeSpecificParams = effect.parameters.cbTypeSpecificParams;
            return 0x800700ea;
        }
        if (flags & 1) output->dwDuration = effect.parameters.dwDuration;
        if (flags & 2) output->dwSamplePeriod = effect.parameters.dwSamplePeriod;
        if (flags & 4) output->dwGain = effect.parameters.dwGain;
        if (flags & 8) output->dwTriggerButton = effect.parameters.dwTriggerButton;
        if (flags & 0x10) output->dwTriggerRepeatInterval = effect.parameters.dwTriggerRepeatInterval;
        if ((flags & 0x20) && effect.parameters.cAxes)
        {
            if (!output->rgdwAxes) return invalidParameters;
            memcpy(&app->getMemory<DWORD>(output->rgdwAxes), effect.axes.data(), effect.parameters.cAxes * 4);
            output->cAxes = effect.parameters.cAxes;
        }
        if ((flags & 0x40) && effect.parameters.cAxes)
        {
            if (!output->rglDirection) return invalidParameters;
            memcpy(&app->getMemory<LONG>(output->rglDirection), effect.directions.data(), effect.parameters.cAxes * 4);
            output->dwFlags = effect.parameters.dwFlags;
        }
        if ((flags & 0x80) && effect.enveloped)
        {
            if (!output->lpEnvelope) return invalidParameters;
            app->getMemory<Envelope>(output->lpEnvelope) = effect.envelope;
        }
        if (flags & 0x100)
        {
            if (!output->lpvTypeSpecificParams) return invalidParameters;
            memcpy(&app->getMemory<LONG>(output->lpvTypeSpecificParams), effect.payload.data(), effect.parameters.cbTypeSpecificParams);
            output->cbTypeSpecificParams = effect.parameters.cbTypeSpecificParams;
        }
        if ((flags & 0x200) && output->dwSize == 56) output->dwStartDelay = effect.parameters.dwStartDelay;
        return 0;
    }
    HRESULT start(WinApplication*, x86::CPU&, DWORD iterations, DWORD flags)
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        auto& effect = state();
        if (!effect.device || !iterations || !effect.parameters.cbTypeSpecificParams) return invalidParameters;
        if (flags & 1) for (auto* other : effects) if (other->device == effect.device) other->playing = other->armed = false;
        effect.downloaded = effect.playing = effect.armed = true;
        effect.repetitions = iterations;
        effect.startTime = effectTime();
        return 0;
    }
    HRESULT stop(WinApplication*, x86::CPU&)
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        state().playing = state().armed = false;
        return 0;
    }
    HRESULT status(WinApplication*, x86::CPU&, DWORD* output)
    {
        if (!output) return invalidParameters;
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        *output = state().running(effectTime()) ? 1 : 0;
        return 0;
    }
    HRESULT download(WinApplication*, x86::CPU&)
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        state().downloaded = true;
        return 0;
    }
    HRESULT unload(WinApplication* app, x86::CPU& cpu)
    {
        std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
        stop(app, cpu); state().downloaded = false;
        return 0;
    }
    HRESULT escape(WinApplication*, x86::CPU&, void*) { return unsupportedEffect; }
    static x86::reg32 initializeTable(WinApplication* app, x86::reg32 address, x86::reg8* memory)
    {
        vtableAddress = address;
        auto* table = reinterpret_cast<uint32_t*>(memory);
        table[0] = 0x400000; table[1] = 0x400001;
#define FORCE_METHOD(slot, method) table[slot] = 0x400e00 + slot; app->registerMethod(table[slot], {"ForceEffect::" #method, &Wrapper<decltype(&ForceEffect::method), &ForceEffect::method>::stdcall});
        FORCE_METHOD(2, release) FORCE_METHOD(3, initialize) FORCE_METHOD(4, guid)
        FORCE_METHOD(5, getParameters) FORCE_METHOD(6, setParameters) FORCE_METHOD(7, start)
        FORCE_METHOD(8, stop) FORCE_METHOD(9, status) FORCE_METHOD(10, download)
        FORCE_METHOD(11, unload) FORCE_METHOD(12, escape)
#undef FORCE_METHOD
        return 13 * sizeof(uint32_t);
    }
};
x86::reg32 ForceEffect::vtableAddress = 0;
}

x86::reg32 initializeForceFeedback(win32::WinApplication* app, x86::reg32 address, x86::reg8* memory)
{
    return ForceEffect::initializeTable(app, address, memory);
}
win32::HRESULT createForceEffect(win32::WinApplication* app, x86::CPU& cpu, win32::Gamepad* pad,
    const win32::GUID* guid, const Parameters* parameters, win32::Packed<win32::com::IUnknown>* output)
{
    if (!output) return invalidParameters;
    *output = win32::Packed<win32::com::IUnknown>();
    if (!pad || !guid || !supports(*guid)) return unsupportedEffect;
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    auto* effect = new EffectState(pad, guid->Data1 - 0x13541c20);
    app->allocateResource(effect);
    devices.try_emplace(pad);
    effects.push_back(effect);
    auto address = win32::com::ComAlloc(app);
    auto* object = new (&app->getMemory<ForceEffect>(address)) ForceEffect(effect);
    if (parameters)
    {
        auto result = object->setParameters(app, cpu, parameters, 0x3ff);
        if (result) { object->release(app, cpu); return result; }
    }
    *output = win32::Packed<win32::com::IUnknown>(address);
    win32::platform::log("NFS3_FORCE_FEEDBACK: create slot=%u kind=%u duration=%u gain=%u", pad->index(), effect->kind, effect->parameters.dwDuration, effect->parameters.dwGain);
    return 0;
}
win32::HRESULT forceEffectInfo(EffectInfo* output, const win32::GUID* guid)
{
    if (!output || !guid || output->dwSize != sizeof(*output)) return invalidParameters;
    if (!supports(*guid)) return unsupportedEffect;
    unsigned kind = guid->Data1 - 0x13541c20;
    const char* names[] = {"Constant force", "Ramp force", "Square wave", "Sine wave", "Triangle wave", "Sawtooth up", "Sawtooth down", "Spring"};
    *output = {};
    output->dwSize = sizeof(*output); output->guid = *guid;
    output->dwEffType = kind == 0 ? 1 : kind == 1 ? 2 : kind == 7 ? 4 : 3;
    output->dwStaticParams = output->dwDynamicParams = 0x3ff;
    strcpy(output->tszName, names[kind]);
    return 0;
}
win32::HRESULT enumerateForceEffects(win32::WinApplication* app, x86::CPU& cpu, x86::reg32 callback, x86::reg32 user, uint32_t filter)
{
    if (!callback) return invalidParameters;
    win32::MemMap memory(sizeof(EffectInfo));
    for (unsigned kind = 0; kind < 8; ++kind)
    {
        auto* info = &app->getMemory<EffectInfo>(memory.getBlockStart());
        info->dwSize = sizeof(*info);
        auto guid = effectGuid(kind);
        forceEffectInfo(info, &guid);
        if ((filter & 0xff) && (filter & 0xff) != info->dwEffType) continue;
        cpu.esp -= 12;
        app->getMemory<uint32_t>(cpu.esp + 4) = memory.getBlockStart();
        app->getMemory<uint32_t>(cpu.esp + 8) = user;
        app->dynamic_call(callback, cpu);
        if (cpu.terminate || !cpu.eax) break;
    }
    return 0;
}
uint32_t forceFeedbackState(win32::Gamepad* pad)
{
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    auto& device = devices[pad];
    bool present = false, running = false;
    for (auto* effect : effects) if (effect->device == pad) { present = true; running |= effect->running(effectTime()); }
    return (!present ? 1 : 0) | (!running ? 2 : 0) | (device.paused ? 4 : 0) | (device.actuators ? 0x10 : 0x20) | 0x40;
}
void forceFeedbackCommand(win32::Gamepad* pad, uint32_t command)
{
    if (!pad) return;
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    auto& device = devices[pad];
    if (command == 1 || command == 2)
    {
        for (auto* effect : effects) if (effect->device == pad)
        {
            effect->playing = effect->armed = false;
            if (command == 1) effect->downloaded = false;
        }
        if (command == 1) device = {};
    }
    if (command == 4 && !device.paused) { device.paused = true; device.pauseTime = effectTime(); }
    if (command == 8 && device.paused)
    {
        for (auto* effect : effects) if (effect->device == pad && effect->playing) effect->startTime += effectTime() - device.pauseTime;
        device.paused = false;
    }
    if (command == 16) device.actuators = true;
    if (command == 32) device.actuators = false;
}
void forceFeedbackGain(win32::Gamepad* pad, uint32_t gain)
{
    if (!pad) return;
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    devices[pad].gain = std::min(gain, 10000u);
}
uint32_t forceFeedbackGain(win32::Gamepad* pad)
{
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    return devices[pad].gain;
}
void detachForceFeedback(win32::Gamepad* pad)
{
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    for (auto* effect : effects) if (effect->device == pad) { effect->device = nullptr; effect->playing = effect->armed = false; }
    devices.erase(pad);
}
ForceFeedbackFrame forceFeedbackFrame(unsigned slot)
{
    std::lock_guard<std::recursive_mutex> guard(feedbackMutex);
    ForceFeedbackFrame output;
    auto now = effectTime();
    for (auto* effect : effects)
    {
        if (!effect->device || effect->device->index() != slot) continue;
        auto& device = devices.at(effect->device);
        if (device.paused || !device.actuators) continue;
        unsigned trigger = effect->parameters.dwTriggerButton;
        if (trigger >= 48 && trigger < 80)
        {
            bool held = (effect->device->getState().buttons & (uint64_t(1) << (trigger - 48))) != 0;
            uint32_t interval = effect->parameters.dwTriggerRepeatInterval;
            if (held && effect->downloaded && (!effect->triggerHeld || (interval && interval != UINT32_MAX && now - effect->triggerTime >= interval)))
            {
                effect->playing = true; effect->repetitions = 1; effect->startTime = effect->triggerTime = now;
            }
            effect->triggerHeld = held;
        }
        float magnitude = effect->magnitude(now) * device.gain / 10000.f;
        if (effect->kind <= 1) output.impact += magnitude;
        else if (effect->kind == 3)
        {
            if (magnitude > output.engine && effect->payload[3] > 0) output.engineHz = 1000000.f / effect->payload[3];
            output.engine += magnitude;
        }
        else output.road += magnitude;
    }
    output.intensity = std::clamp(output.impact + 0.3f * (output.road + output.engine), 0.f, 1.f);
    output.impact = std::clamp(output.impact, 0.f, 1.f);
    output.road = std::clamp(output.road, 0.f, 1.f);
    output.engine = std::clamp(output.engine, 0.f, 1.f);
    return output;
}
}
