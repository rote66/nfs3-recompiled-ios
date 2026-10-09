#pragma once

#include <winapi/dinput/idirectinputdevice.h>

namespace nfsios
{
struct ForceFeedbackFrame
{
    float intensity = 0;
    float impact = 0;
    float road = 0;
    float engine = 0;
    float engineHz = 0;
};
x86::reg32 initializeForceFeedback(win32::WinApplication* app, x86::reg32 address, x86::reg8* memory);
win32::HRESULT createForceEffect(win32::WinApplication* app, x86::CPU& cpu, win32::Gamepad* pad,
    const win32::GUID* guid, const win32::dinput::IDirectInputDevice::DIEFFECT* parameters, win32::Packed<win32::com::IUnknown>* output);
win32::HRESULT enumerateForceEffects(win32::WinApplication* app, x86::CPU& cpu, x86::reg32 callback, x86::reg32 user, uint32_t filter);
win32::HRESULT forceEffectInfo(win32::dinput::IDirectInputDevice::DIEffectInfo* output, const win32::GUID* guid);
uint32_t forceFeedbackState(win32::Gamepad* pad);
void forceFeedbackCommand(win32::Gamepad* pad, uint32_t command);
void forceFeedbackGain(win32::Gamepad* pad, uint32_t gain);
uint32_t forceFeedbackGain(win32::Gamepad* pad);
void detachForceFeedback(win32::Gamepad* pad);
ForceFeedbackFrame forceFeedbackFrame(unsigned slot);
void forceFeedbackDiagnostic();
void updateHaptics(bool playing);
void stopHaptics();
void setHapticsEnabled(bool enabled);
void hapticsDiagnostic();
float corneringForce();
}
