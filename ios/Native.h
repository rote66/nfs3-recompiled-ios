#pragma once

#include <cstdint>
#include <lib/gamepad.h>

namespace nfsios
{
void key(uint32_t virtualKey, bool down, unsigned source = 0);
void character(uint32_t value);
void keyboardState(void* bytes, unsigned count);
void pointer(double horizontal, double vertical, int button);
void setCursorPosition(int horizontal, int vertical);
unsigned readMouse(win32::WinApplication* app, void* records, unsigned stride, unsigned capacity, bool peek);
void readMouseState(void* bytes, unsigned count);
void setRaceActive(bool value);
void updateGameState(win32::WinApplication* app);
enum class DrivingMode { Keyboard, Tilt, Controller };
void requestDrivingMode(DrivingMode mode);
void updateDrivingMode(win32::WinApplication* app, x86::CPU& cpu);
void drivingModeDiagnostic(const char* directory);
bool takingText();
bool manualGears();
bool policeCar();
void presentationSize(double& width, double& height);
void shutdownServices(win32::WinApplication* app);
void releaseInput();
void setController(unsigned index, const win32::GamepadState& state);
win32::GamepadState controller(unsigned index);
void setActive(bool active);
bool isActive();
void waitActive();
void wakeMessages();
void attachMetal(void* view);
void presentTexture(void* texture);
void* metalDevice();
double framesPerSecond();
double gpuMilliseconds();
bool isRunning();
bool inRace();
void runGame(const char* directory, bool initializeControls, DrivingMode mode);
bool controlsInitialized();
void stopGame();
bool audioActive(bool active);
bool audioRunning();
void graphicsDiagnostic();
void graphicsIntegrationDiagnostic();
void graphicsConcurrencyDiagnostic();
void graphicsAllocationDiagnostic();
enum class RenderAllocation { None, Color, Depth, Vertices };
void failNextRenderAllocation(RenderAllocation allocation);
uint64_t renderAllocationCount(RenderAllocation allocation);
void setRenderDiagnosticHook(void (*hook)(void*, bool), void* context);
void inputDiagnostic();
void gameInputDiagnostic();
void timerDiagnostic();
void networkDiagnostic(const char* directory);
void networkPeerDiagnostic();
bool audioDiagnostic();
void filesystemDiagnostic();
}
