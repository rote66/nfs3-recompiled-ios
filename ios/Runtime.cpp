#include "Native.h"
#include "ForceFeedback.h"
#include "LANDiscovery.h"
#include <lib/window.h>
#include <lib/thread.h>
#include <lib/timer.h>
#include <lib/mutex.h>
#include <lib/event.h>
#include <lib/file.h>
#include <lib/registry.h>
#include <winapi/kernel32.h>
#include <winapi/winmm.h>
#include <nfs3hp.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <thread>
#include <ctime>
#include <cmath>
#include <system_error>

namespace
{
std::mutex messageMutex;
std::condition_variable messageCondition;
std::deque<win32::MSG> messages;
std::mutex inputMutex;
uint8_t heldKeys[256]{};
win32::GamepadState controllers[2]{};
std::mutex activeMutex;
std::condition_variable activeCondition;
bool active = true;
uint64_t pausedNanoseconds = 0;
uint64_t pauseBegan = 0;
std::atomic<bool> running{false};
std::atomic<bool> stopping{false};
std::atomic<unsigned> nextThread{2};
thread_local unsigned threadId = 1;
std::mutex eventMutex;
std::condition_variable eventCondition;
std::atomic<unsigned> nextEvent{0};
win32::WindowClass* windowClass = nullptr;
std::mutex applicationMutex;
nfs3hp::Application* application = nullptr;
std::atomic<bool> driving{false}, textEntry{false}, gears{true}, spikes{true};
std::atomic<float> cornering{0};
std::atomic<bool> raceActive{false};
bool controlsPending = false;
std::atomic<nfsios::DrivingMode> drivingMode{nfsios::DrivingMode::Keyboard};
std::atomic<nfsios::DrivingMode> requestedDrivingMode{nfsios::DrivingMode::Keyboard};
std::atomic<bool> drivingModePending{false};
std::atomic<bool> installedControls{false};
struct PointerSample { double horizontal, vertical; int button; };
std::deque<PointerSample> pointerSamples;
bool pointerHeld = false;
unsigned pointerSequence = 0;
unsigned pointerTrace = 0;
std::deque<std::array<uint32_t, 4>> mouseRecords;
int32_t mouseHorizontal = 0, mouseVertical = 0;
bool pointerObserved = false;
std::atomic<unsigned> diagnosticWorkers{0};
struct NativeService
{
    win32::WinApplication* app = nullptr;
    x86::CPU cpu{};
    std::thread worker;
    std::mutex mutex;
    std::condition_variable condition;
    bool resumed = false;
    bool cancelled = false;
    virtual void requestStop()
    {
        cpu.terminate = true;
        { std::lock_guard<std::mutex> guard(mutex); resumed = true; cancelled = true; }
        condition.notify_all();
    }
    void join()
    {
        if (worker.joinable() && worker.get_id() != std::this_thread::get_id()) worker.join();
    }
    virtual ~NativeService()
    {
        if (worker.joinable())
        {
            if (worker.get_id() == std::this_thread::get_id()) worker.detach();
            else worker.join();
        }
    }
};
std::mutex servicesMutex;
std::vector<std::weak_ptr<NativeService>> services;
void registerService(const std::shared_ptr<NativeService>& service, win32::WinApplication* app)
{
    service->app = app;
    std::lock_guard<std::mutex> guard(servicesMutex);
    services.erase(std::remove_if(services.begin(), services.end(), [](const auto& item) { return item.expired(); }), services.end());
    services.push_back(service);
}

struct TimerScheduler;
struct ScheduledTimer
{
    win32::WinApplication* app;
    uint32_t procedure;
    uint32_t parameter;
    uint32_t delay;
    uint32_t handle = 0;
    x86::CPU cpu{};
    std::chrono::steady_clock::time_point deadline;
    std::weak_ptr<TimerScheduler> scheduler;
    bool cancelled = false;
    bool completed = false;
};
struct TimerScheduler : NativeService
{
    std::map<uint32_t, std::shared_ptr<ScheduledTimer>> timers;
    std::shared_ptr<ScheduledTimer> current;
    void requestStop() override
    {
        {
            std::lock_guard<std::mutex> guard(mutex);
            cancelled = true;
            for (auto& item : timers)
            {
                item.second->cancelled = true;
                item.second->completed = true;
                item.second->cpu.terminate = true;
            }
            timers.clear();
            if (current) { current->cancelled = true; current->cpu.terminate = true; }
        }
        condition.notify_all();
    }
};
std::mutex timerSchedulersMutex;
std::map<win32::WinApplication*, std::weak_ptr<TimerScheduler>> timerSchedulers;
std::atomic<unsigned> timerWorkersCreated{0};
std::atomic<unsigned> timerWorkersActive{0};
std::atomic<uint64_t> timerCallbacksCompleted{0};
std::atomic<bool> failTimerWorker{false};
thread_local TimerScheduler* executingTimerScheduler = nullptr;
std::shared_ptr<TimerScheduler> schedulerFor(win32::WinApplication* app, bool create)
{
    std::lock_guard<std::mutex> guard(timerSchedulersMutex);
    auto found = timerSchedulers.find(app);
    if (found != timerSchedulers.end())
        if (auto scheduler = found->second.lock()) return scheduler;
    if (!create) return {};
    auto scheduler = std::make_shared<TimerScheduler>();
    registerService(scheduler, app);
    try
    {
        if (failTimerWorker.exchange(false)) throw std::system_error(std::make_error_code(std::errc::resource_unavailable_try_again), "timer worker");
        scheduler->worker = std::thread([scheduler] {
            ++timerWorkersActive;
            threadId = nextThread++;
            executingTimerScheduler = scheduler.get();
            for (;;)
            {
                std::shared_ptr<ScheduledTimer> timer;
                {
                    std::unique_lock<std::mutex> guard(scheduler->mutex);
                    if (scheduler->cancelled) break;
                    if (scheduler->timers.empty())
                    {
                        scheduler->condition.wait(guard);
                        continue;
                    }
                    auto next = std::min_element(scheduler->timers.begin(), scheduler->timers.end(), [](const auto& first, const auto& second) {
                        return first.second->deadline < second.second->deadline;
                    });
                    if (std::chrono::steady_clock::now() < next->second->deadline)
                    {
                        auto deadline = next->second->deadline;
                        scheduler->condition.wait_until(guard, deadline);
                        continue;
                    }
                    timer = next->second;
                    scheduler->timers.erase(next);
                    scheduler->current = timer;
                }
                if (!timer->cpu.terminate) timer->app->runThread(timer->cpu, timer->procedure, timer->parameter);
                {
                    std::lock_guard<std::mutex> guard(scheduler->mutex);
                    timer->completed = true;
                }
                scheduler->condition.notify_all();
                timer->app->freeResourceIfPresent(timer->handle);
                {
                    std::lock_guard<std::mutex> guard(scheduler->mutex);
                    scheduler->current.reset();
                    ++timerCallbacksCompleted;
                }
                scheduler->condition.notify_all();
            }
            executingTimerScheduler = nullptr;
            --timerWorkersActive;
        });
    }
    catch (const std::system_error& error)
    {
        win32::platform::log("NFS3_TIMER: worker unavailable error=%d", error.code().value());
        return {};
    }
    ++timerWorkersCreated;
    timerSchedulers[app] = scheduler;
    return scheduler;
}
void cancelTimer(const std::shared_ptr<ScheduledTimer>& timer, x86::CPU* caller)
{
    auto scheduler = timer->scheduler.lock();
    if (!scheduler) return;
    bool wait;
    {
        std::lock_guard<std::mutex> guard(scheduler->mutex);
        timer->cancelled = true;
        bool currentThread = executingTimerScheduler == scheduler.get();
        if (!currentThread) timer->cpu.terminate = true;
        if (scheduler->current != timer)
        {
            scheduler->timers.erase(timer->handle);
            timer->completed = true;
        }
        wait = !timer->completed && !currentThread;
    }
    scheduler->condition.notify_all();
    if (wait)
    {
        if (caller) timer->app->unlockContext(*caller);
        win32::Event::broadcastTerminate();
        nfsios::wakeMessages();
        {
            std::unique_lock<std::mutex> guard(scheduler->mutex);
            scheduler->condition.wait(guard, [&] { return timer->completed; });
        }
        if (caller) timer->app->lockContext(*caller);
    }
}

struct TimerDiagnosticState
{
    unsigned command = 0;
    uint32_t delay = 0;
    uint32_t procedure = 0;
    uint32_t parameter = 0;
    uint32_t handle = 0;
    uint32_t result = 0;
    std::atomic<unsigned> fired{0};
    std::atomic<unsigned> waiting{0};
    std::atomic<unsigned> cancelled{0};
    std::atomic<uint32_t> selfHandle{0};
};
std::atomic<TimerDiagnosticState*> timerDiagnosticState{nullptr};

unsigned scanCode(unsigned key)
{
    switch (key)
    {
    case 13: return 0x1c;
    case 8: return 0x0e;
    case 9: return 0x0f;
    case 27: return 0x01;
    case 32: return 0x39;
    case 37: return 0x4b;
    case 38: return 0x48;
    case 39: return 0x4d;
    case 40: return 0x50;
    default:
        if (key >= 'A' && key <= 'Z')
        {
            static const unsigned letters[] = {0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
            return letters[key - 'A'];
        }
        if (key >= '1' && key <= '9') return key - '1' + 2;
        if (key == '0') return 0x0b;
        return 0;
    }
}
}

namespace nfsios
{
[[noreturn]] void assertionFailed(const char* expression, const char* file, unsigned line)
{
    win32::platform::log("NFS3_ASSERT: %s:%u: %s", file, line, expression);
    fflush(stderr);
    __builtin_trap();
}
void key(uint32_t virtualKey, bool down, unsigned source)
{
    if (virtualKey >= 256 || source >= 3) return;
    std::lock_guard<std::mutex> guard(inputMutex);
    bool wasDown = heldKeys[virtualKey] != 0;
    if (down) heldKeys[virtualKey] |= 1u << source;
    else heldKeys[virtualKey] &= ~(1u << source);
    down = heldKeys[virtualKey] != 0;
    if (wasDown == down) return;
    uint32_t parameter = 1 | (scanCode(virtualKey) << 16);
    if (!down) parameter |= 0xc0000000u;
    win32::Window::postMessage(0, down ? 0x100 : 0x101, virtualKey, parameter);
    if (down && virtualKey >= 8 && virtualKey < 32)
        win32::Window::postMessage(0, 0x102, virtualKey, parameter);
}
void releaseInput()
{
    for (unsigned index = 0; index < 256; ++index)
        for (unsigned source = 0; source < 3; ++source) key(index, false, source);
    std::lock_guard<std::mutex> guard(inputMutex);
    memset(controllers, 0, sizeof(controllers));
    pointerSamples.clear();
    if (pointerHeld) pointerSamples.push_back({-1, -1, 0});
}
void character(uint32_t value)
{
    if (value >= 32 && value <= 255) win32::Window::postMessage(0, 0x102, value, 1);
}
void keyboardState(void* bytes, unsigned count)
{
    std::lock_guard<std::mutex> guard(inputMutex);
    auto state = static_cast<uint8_t*>(bytes);
    for (unsigned key = 0; key < 256; ++key)
    {
        unsigned scan = scanCode(key);
        if (scan && scan < count && heldKeys[key]) state[scan] = 0x80;
    }
}
void pointer(double horizontal, double vertical, int button)
{
    horizontal = std::clamp(horizontal, 0.0, 1.0);
    vertical = std::clamp(vertical, 0.0, 1.0);
    {
        std::lock_guard<std::mutex> guard(inputMutex);
        if (driving) return;
        if (!pointerSamples.empty() && pointerSamples.back().button == -1) pointerSamples.pop_back();
        if (pointerSamples.size() >= 128) return;
        pointerSamples.push_back({horizontal, vertical, button});
        if (pointerTrace++ < 96)
            win32::platform::log("NFS3_TOUCH_QUEUE: x=%.3f y=%.3f button=%d pending=%zu", horizontal, vertical, button, pointerSamples.size());
    }
    double width, height;
    presentationSize(width, height);
    uint32_t position = uint32_t(std::lround(horizontal * (width - 1))) | uint32_t(std::lround(vertical * (height - 1))) << 16;
    win32::Window::postMessage(0, button < 0 ? 0x200 : button ? 0x201 : 0x202, button > 0 ? 1 : 0, position);
}
void pumpPointer(win32::WinApplication* app)
{
    std::lock_guard<std::mutex> guard(inputMutex);
    if (driving)
    {
        pointerSamples.clear();
        if (pointerHeld) pointerSamples.push_back({-1, -1, 0});
    }
    if (pointerSamples.empty()) return;
    int lowX = app->getMemory<int32_t>(0x5f38e0), lowY = app->getMemory<int32_t>(0x5f38e4);
    int highX = app->getMemory<int32_t>(0x5f38e8), highY = app->getMemory<int32_t>(0x5f38ec);
    int cursorX = app->getMemory<int32_t>(0x5f38f0), cursorY = app->getMemory<int32_t>(0x5f38f4);
    for (const auto& record : mouseRecords)
    {
        if (record[0] == 0) cursorX += int32_t(record[1]);
        if (record[0] == 4) cursorY += int32_t(record[1]);
    }
    auto append = [&](uint32_t offset, int32_t value) {
        mouseRecords.push_back({offset, uint32_t(value), win32::timeGetTickCount(), ++pointerSequence});
    };
    while (!pointerSamples.empty())
    {
        auto sample = pointerSamples.front();
        if (sample.button == 0 && pointerHeld && !pointerObserved && !driving) break;
        if (sample.horizontal >= 0 && (highX <= lowX || highY <= lowY)) break;
        if (sample.horizontal >= 0)
        {
            int targetX = lowX + int(std::lround(sample.horizontal * (highX - lowX)));
            int targetY = lowY + int(std::lround(sample.vertical * (highY - lowY)));
            int deltaX = targetX - cursorX, deltaY = targetY - cursorY;
            if (deltaX) append(0, deltaX);
            if (deltaY) append(4, deltaY);
            mouseHorizontal += deltaX; mouseVertical += deltaY;
            cursorX = targetX; cursorY = targetY;
        }
        bool transition = sample.button >= 0 && bool(sample.button) != pointerHeld;
        if (transition)
        {
            pointerHeld = sample.button;
            pointerObserved = false;
            append(12, pointerHeld ? 0x80 : 0);
        }
        pointerSamples.pop_front();
        if (pointerTrace++ < 96)
            win32::platform::log("NFS3_TOUCH_FRAME: cursor=%d,%d bounds=%d,%d..%d,%d button=%d records=%zu", cursorX, cursorY, lowX, lowY, highX, highY, sample.button, mouseRecords.size());
        if (transition) break;
    }
}
void setCursorPosition(int horizontal, int vertical)
{
    std::lock_guard<std::mutex> guard(inputMutex);
    uint32_t position = uint32_t(uint16_t(horizontal)) | uint32_t(uint16_t(vertical)) << 16;
    win32::Window::postMessage(0, 0x200, pointerHeld ? 1 : 0, position);
    if (pointerTrace++ < 96)
        win32::platform::log("NFS3_CURSOR_WARP: x=%d y=%d held=%d", horizontal, vertical, pointerHeld);
}
unsigned readMouse(win32::WinApplication* app, void* records, unsigned stride, unsigned capacity, bool peek)
{
    (void)app;
    if (stride < 16) return 0;
    std::lock_guard<std::mutex> guard(inputMutex);
    unsigned count = std::min(size_t(capacity), mouseRecords.size());
    if (!records) return count;
    for (unsigned index = 0; index < count; ++index)
    {
        auto destination = static_cast<uint8_t*>(records) + index * stride;
        memset(destination, 0, stride);
        memcpy(destination, mouseRecords[index].data(), 16);
        if (!peek && mouseRecords[index][0] == 12 && mouseRecords[index][1] == 0x80) pointerObserved = true;
    }
    if (!peek)
    {
        mouseRecords.erase(mouseRecords.begin(), mouseRecords.begin() + count);
        if (count && pointerTrace++ < 96) win32::platform::log("NFS3_TOUCH_DELIVER: buffered count=%u stride=%u", count, stride);
    }
    return count;
}
void readMouseState(void* bytes, unsigned count)
{
    if (count < 16) return;
    std::lock_guard<std::mutex> guard(inputMutex);
    int32_t motion[] = {mouseHorizontal, mouseVertical, 0};
    memcpy(bytes, motion, sizeof(motion));
    static_cast<uint8_t*>(bytes)[12] = pointerHeld ? 0x80 : 0;
    if ((mouseHorizontal || mouseVertical || pointerHeld) && pointerTrace++ < 96)
        win32::platform::log("NFS3_TOUCH_STATE: movement=%d,%d held=%d", mouseHorizontal, mouseVertical, pointerHeld);
    mouseHorizontal = mouseVertical = 0;
    if (pointerHeld) pointerObserved = true;
}
void setRaceActive(bool value)
{
    if (raceActive.exchange(value) != value)
        win32::platform::log("NFS3_RACE: active=%d", value);
}
void updateGameState(win32::WinApplication* app)
{
    bool previousDriving = driving;
    bool previousText = textEntry;
    driving = raceActive && app->getMemory<uint32_t>(0x7a3d10) == 0 && app->getMemory<uint32_t>(0x6fd3a0) != 2;
    textEntry = !driving && app->getMemory<uint8_t>(0x558b10) != 0 && app->getMemory<uint32_t>(0x558b14) == 3;
    if (previousDriving != driving)
        win32::platform::log("NFS3_INPUT_MODE: driving=%d race=%d pause=%u mode=%u", bool(driving), bool(raceActive), unsigned(app->getMemory<uint32_t>(0x7a3d10)), unsigned(app->getMemory<uint32_t>(0x6fd3a0)));
    if (previousText != textEntry)
        win32::platform::log("NFS3_TEXT_INPUT: active=%d mode=%u callback=%08x", bool(textEntry), unsigned(app->getMemory<uint32_t>(0x558b14)), unsigned(app->getMemory<uint32_t>(0x558b18)));
    pumpPointer(app);
    cornering = 0;
    if (controlsPending && app->getMemory<uint32_t>(0x6fbb40) == 0x20f0)
    {
        for (unsigned index = 0; index < 13; ++index)
        {
            uint32_t binding = app->getMemory<uint32_t>(0x490430 + index * 4);
            app->getMemory<uint32_t>(0x6fd20c + index * 4) = binding;
            app->getMemory<uint32_t>(0x6fd240 + index * 4) = binding;
        }
        if (drivingMode != DrivingMode::Keyboard)
        {
            const uint32_t axes[] = {0x0080ff01,0x007f0001,0x017f0001,0x0180ff01};
            for (unsigned index = 0; index < (drivingMode == DrivingMode::Tilt ? 2u : 4u); ++index)
            {
                app->getMemory<uint32_t>(0x6fd20c + index * 4) = axes[index];
                app->getMemory<uint32_t>(0x6fd240 + index * 4) = axes[index];
            }
        }
        uint32_t secondPlayer[] = {0x1080ff01, 0x107f0001, 0x117f0001, 0x1180ff01};
        for (unsigned index = 0; index < 4; ++index) app->getMemory<uint32_t>(0x6fd274 + index * 4) = secondPlayer[index];
        const unsigned playerTwoKeys[] = {'D','F','G','Q','W','E','X','P','Y'};
        for (unsigned index = 0; index < 9; ++index)
            app->getMemory<uint32_t>(0x6fd284 + index * 4) = 4 | scanCode(playerTwoKeys[index]) << 8 | playerTwoKeys[index] << 24;
        controlsPending = false;
        drivingModePending = true;
        installedControls = true;
        win32::platform::log("NFS3_CONTROLS: mode=%u driving; original action keys", unsigned(drivingMode.load()));
    }
    if (driving)
    {
        uint32_t view = app->getMemory<uint32_t>(0x5e10b0);
        uint32_t car = view ? uint32_t(app->getMemory<uint32_t>(view + 8)) : 0;
        if (car)
        {
            uint32_t player = app->getMemory<uint32_t>(car + 0x220);
            if (player >= 0x6fd52c && player < 0x6fd52c + 16 * 0x6c && (player - 0x6fd52c) % 0x6c == 0)
            {
                gears = app->getMemory<uint32_t>(player + 0x1c) != 1;
                spikes = (app->getMemory<uint8_t>(car + 0x200) & 0x20) != 0;
                app->getMemory<uint32_t>(player + 0x24) = drivingMode == DrivingMode::Keyboard ? 1 : 0;
                float scale = app->getMemory<float>(0x5efde4);
                if (scale > 0 && app->getMemory<uint16_t>(car + 0x164) == 0 && app->getMemory<float>(car + 0x15c) >= 0)
                    cornering = std::clamp(std::abs(float(app->getMemory<float>(car + 0x924))) / scale, 0.f, 1.f);
            }
        }
    }
}
bool inRace() { return driving; }
bool takingText() { return textEntry; }
bool manualGears() { return gears; }
bool policeCar() { return spikes; }
float corneringForce() { return cornering; }
void requestDrivingMode(DrivingMode mode)
{
    if (requestedDrivingMode.exchange(mode) != mode) drivingModePending = true;
}
void updateDrivingMode(win32::WinApplication* app, x86::CPU& cpu)
{
    if (controlsPending || app->getMemory<uint32_t>(0x6fbb40) != 0x20f0) return;
    bool changed = drivingModePending.exchange(false);
    DrivingMode mode = requestedDrivingMode;
    const uint32_t axisBindings[] = {0x0080ff01,0x007f0001,0x017f0001,0x0180ff01};
    for (unsigned index = 0; index < 13; ++index)
    {
        bool axis = (mode == DrivingMode::Controller && index < 4) || (mode == DrivingMode::Tilt && index < 2);
        uint32_t binding = axis ? axisBindings[index] : uint32_t(app->getMemory<uint32_t>(0x490430 + index * 4));
        for (unsigned table : {0x6fd20cu, 0x6fd240u})
        {
            auto current = app->getMemory<uint32_t>(table + index * 4);
            if (current != binding) { current = binding; changed = true; }
        }
    }
    if (!changed) return;
    drivingMode = mode;
    std::array<uint32_t, 10> savedRegisters = {cpu.eax,cpu.ebx,cpu.ecx,cpu.edx,cpu.esi,cpu.edi,cpu.ebp,cpu.esp,cpu.ip,cpu.flags.eflags};
    for (unsigned refresh : {0x43c040u, 0x48f1f0u})
    {
        cpu.esp -= 4;
        app->dynamic_call(refresh, cpu);
    }
    cpu.eax = savedRegisters[0]; cpu.ebx = savedRegisters[1]; cpu.ecx = savedRegisters[2]; cpu.edx = savedRegisters[3];
    cpu.esi = savedRegisters[4]; cpu.edi = savedRegisters[5]; cpu.ebp = savedRegisters[6]; cpu.esp = savedRegisters[7];
    cpu.ip = savedRegisters[8]; cpu.flags.eflags = savedRegisters[9];
    if (app->getMemory<uint32_t>(0x6fd3a0) != 2)
    {
        uint32_t car = app->getMemory<uint32_t>(0x678b54);
        if (car)
        {
            uint32_t player = app->getMemory<uint32_t>(car + 0x220);
            if (player >= 0x6fd52c && player < 0x6fd52c + 16 * 0x6c && (player - 0x6fd52c) % 0x6c == 0)
                app->getMemory<uint32_t>(player + 0x24) = mode == DrivingMode::Keyboard ? 1 : 0;
        }
    }
    bool saved = false;
    {
        win32::File file("fedata\\config\\config.dat", win32::GENERIC_READ | win32::GENERIC_WRITE, 0, win32::OPEN_EXISTING);
        if (static_cast<void*>(file) && file.size() == 0x20f0)
        {
            saved = true;
            for (unsigned offset : {0x16ccu, 0x1700u})
            {
                uint32_t written = 0;
                saved = saved && file.seek(0, offset) == offset
                    && file.write(&app->getMemory<uint8_t>(0x6fbb40 + offset), 52, &written) && written == 52;
            }
        }
    }
    installedControls = true;
    const char* name = mode == DrivingMode::Tilt ? "tilt-steering+keyboard-pedals" : mode == DrivingMode::Controller ? "controller" : "keyboard";
    win32::platform::log("NFS3_DRIVING_PROFILE: mode=%s live=applied steering=%u pedals=%u,%u actions=keyboard config=%s", name, unsigned(app->getMemory<uint32_t>(0x6fd2dc)), unsigned(app->getMemory<uint32_t>(0x6fd2e0)), unsigned(app->getMemory<uint32_t>(0x6fd2e4)), saved ? "saved" : "deferred to game save");
}
void setController(unsigned index, const win32::GamepadState& state)
{
    std::lock_guard<std::mutex> guard(inputMutex);
    if (index < 2) controllers[index] = state;
}
win32::GamepadState controller(unsigned index)
{
    std::lock_guard<std::mutex> guard(inputMutex);
    if (index >= 2) return {};
    auto state = controllers[index];
    if (index == 0 && drivingMode != DrivingMode::Keyboard)
    {
        auto touch = [](unsigned key) { return (heldKeys[key] & 1) != 0; };
        if (touch(37) || touch(39)) state.axes[0] = (int(touch(39)) - int(touch(37))) * 32767;
        if (drivingMode == DrivingMode::Controller && (touch(38) || touch(40))) state.axes[1] = (int(touch(40)) - int(touch(38))) * 32767;
    }
    return state;
}
void setActive(bool value)
{
    if (!value) releaseInput();
    {
        std::lock_guard<std::mutex> guard(activeMutex);
        uint64_t now = win32::platform::nanoseconds();
        if (active && !value) pauseBegan = now;
        if (!active && value) pausedNanoseconds += now - pauseBegan;
        if (active != value) win32::platform::log("NFS3_ACTIVITY: active=%d", value);
        active = value;
    }
    activeCondition.notify_all();
}
bool isActive()
{
    std::lock_guard<std::mutex> guard(activeMutex);
    return active;
}
void waitActive()
{
    std::unique_lock<std::mutex> guard(activeMutex);
    activeCondition.wait(guard, [] { return active || stopping.load(); });
}
void wakeMessages() { messageCondition.notify_all(); }
bool isRunning() { return running.load(); }
void inputDiagnostic()
{
    NFS2_ASSERT(!running);
    stopping = false;
    releaseInput();
    { std::lock_guard<std::mutex> guard(messageMutex); messages.clear(); }
    x86::CPU cpu{};
    win32::MSG message{};
    key(37, true, 0);
    key(37, true, 1);
    key(37, false, 0);
    key(37, false, 1);
    NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == 0x100 && message.wParam == 37);
    NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == 0x101 && message.wParam == 37);
    { std::lock_guard<std::mutex> guard(messageMutex); NFS2_ASSERT(messages.empty()); }
    key(13, true);
    key(13, false);
    for (unsigned expected : {0x100, 0x102, 0x101})
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expected && message.wParam == 13);
    win32::GamepadState state{};
    state.axes[0] = 12000; state.buttons = 4;
    setController(0, state);
    setController(1, state);
    NFS2_ASSERT(controller(1).axes[0] == 12000 && controller(1).buttons == 4);
    key(37, true);
    NFS2_ASSERT(controller(0).axes[0] == 12000);
    uint8_t keyboard[256]{};
    keyboardState(keyboard, sizeof(keyboard));
    NFS2_ASSERT(keyboard[0x4b] == 0x80);
    for (unsigned virtualKey : {'A','Z','C','H','B','R','S','L'})
    {
        key(virtualKey, true);
        keyboardState(keyboard, sizeof(keyboard));
        NFS2_ASSERT(keyboard[scanCode(virtualKey)] == 0x80);
        key(virtualKey, false);
    }
    setActive(false);
    uint64_t frozen = win32::platform::guestNanoseconds();
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    NFS2_ASSERT(win32::platform::guestNanoseconds() == frozen);
    NFS2_ASSERT(controller(0).axes[0] == 0 && controller(1).buttons == 0);
    setActive(true);
    { std::lock_guard<std::mutex> guard(messageMutex); messages.clear(); }
    character('N'); character('3'); key(8, true); key(8, false);
    const unsigned expectedMessages[] = {0x102,0x102,0x100,0x102,0x101};
    const unsigned expectedValues[] = {'N','3',8,8,8};
    for (unsigned index = 0; index < 5; ++index)
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expectedMessages[index] && message.wParam == expectedValues[index]);
    win32::platform::log("NATIVE_INPUT_DIAGNOSTIC: PASS multi-source keys, original scan codes, direct typing/deletion, separate keyboard/controller inputs, lifecycle release and frozen guest clock");
}
void stopGame()
{
    stopping = true;
    setActive(true);
    std::lock_guard<std::mutex> guard(applicationMutex);
    if (application) application->terminate();
    win32::Window::postMessage(0, 0x12, 0, 0);
    eventCondition.notify_all();
}
bool controlsInitialized() { return installedControls; }
void runGame(const char* directory, bool initializeControls, DrivingMode mode)
{
    if (running.exchange(true)) return;
    stopping = false;
    controlsPending = initializeControls;
    installedControls = false;
    drivingMode = mode;
    requestedDrivingMode = mode;
    drivingModePending = true;
    setRaceActive(false);
    driving = false; textEntry = false;
    {
        std::lock_guard<std::mutex> guard(inputMutex);
        pointerSamples.clear(); mouseRecords.clear(); pointerHeld = pointerObserved = false;
        mouseHorizontal = mouseVertical = 0; pointerSequence = pointerTrace = 0;
    }
    { std::lock_guard<std::mutex> guard(messageMutex); messages.clear(); }
    win32::File::setDataDirectory(directory);
    win32::File::setCdDirectory(directory);
    win32::File::setCurrentDirectory("c:\\nfs3\\");
    {
        nfs3hp::Application game("nfs3.exe");
        { std::lock_guard<std::mutex> guard(applicationMutex); application = &game; }
        auto stringValue = [&](const char* name, const char* value) {
            game.addRegistryKey(win32::HKEY_LOCAL_MACHINE, "SOFTWARE\\Electronic Arts\\Need For Speed III", name, new win32::RegistryValue(value));
        };
        auto integerValue = [&](const char* name, uint32_t value) {
            game.addRegistryKey(win32::HKEY_LOCAL_MACHINE, "SOFTWARE\\Electronic Arts\\Need For Speed III", name, new win32::RegistryValue(value));
        };
        stringValue("3D Device Description", "3Dfx Voodoo 2");
        stringValue("3D Card", "3Dfx Voodoo 2");
        stringValue("Thrash Driver", "voodoo2");
        stringValue("Group", "3Dfx");
        integerValue("D3D Device", 0);
        integerValue("Triple Buffer", 0);
        integerValue("Hardware Acceleration", 1);
        if (!stopping) game.execute();
        stopping = true;
        setActive(true);
        { std::lock_guard<std::mutex> guard(applicationMutex); application = nullptr; }
    }
    stopLANAccess();
    releaseInput();
    setRaceActive(false);
    driving = false; textEntry = false;
    running = false;
}
void shutdownServices(win32::WinApplication* app)
{
    std::vector<std::shared_ptr<NativeService>> pending;
    {
        std::lock_guard<std::mutex> guard(servicesMutex);
        for (auto& item : services)
            if (auto service = item.lock(); service && service->app == app) pending.push_back(service);
    }
    for (auto& service : pending) service->requestStop();
    eventCondition.notify_all();
    activeCondition.notify_all();
    messageCondition.notify_all();
    for (auto& service : pending) service->join();
}
void drivingModeDiagnostic(const char* directory)
{
    NFS2_ASSERT(!running);
    win32::File::setDataDirectory(directory);
    win32::File::setCdDirectory(directory);
    nfs3hp::Application game("nfs3.exe");
    std::array<uint8_t, 0x20f0> expected{};
    for (unsigned index = 0; index < expected.size(); ++index) expected[index] = uint8_t(index * 37 + 19);
    uint32_t size = expected.size();
    memcpy(expected.data(), &size, sizeof(size));
    for (unsigned address : {0x6fd3b0u, 0x6fd3a0u})
    {
        uint32_t value = 0;
        memcpy(expected.data() + address - 0x6fbb40, &value, 4);
    }
    for (unsigned slot = 0; slot < 2; ++slot) expected[0x6fc970 - 0x6fbb40 + slot * 0x88] = 8;
    for (unsigned index = 0; index < 4; ++index)
    {
        uint32_t binding = game.getMemory<uint32_t>(0x490430 + index * 4);
        memcpy(expected.data() + 0x6fd274 - 0x6fbb40 + index * 4, &binding, 4);
    }
    memcpy(&game.getMemory<uint8_t>(0x6fbb40), expected.data(), expected.size());
    win32::MemMap vehicle(0x1000);
    game.getMemory<uint32_t>(vehicle.getBlockStart() + 0x220) = 0x6fd52c;
    game.getMemory<uint32_t>(0x678b54) = vehicle.getBlockStart();
    {
        win32::File file("fedata\\config\\config.dat", win32::GENERIC_WRITE, 0, win32::CREATE_ALWAYS);
        uint32_t written = 0;
        NFS2_ASSERT(file.write(expected.data(), expected.size(), &written));
    }
    x86::CPU initialization{};
    NFS2_ASSERT(game.runThread(initialization, 0x4350a0) == 1);
    game.registerMethod(0x400ffd, {"DrivingProfilePollDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        uint32_t device = app->getMemory<uint32_t>(0x554ee8);
        cpu.ebx = 0x13245768; cpu.edi = 0x87654321;
        auto stack = cpu.esp;
        cpu.esp -= 16;
        app->getMemory<uint32_t>(cpu.esp + 4) = device;
        app->getMemory<uint32_t>(cpu.esp + 8) = 16;
        app->getMemory<uint32_t>(cpu.esp + 12) = 0x5f3920;
        app->dynamic_call(app->getMemory<uint32_t>(app->getMemory<uint32_t>(device) + 36), cpu);
        cpu.esp += 4;
        NFS2_ASSERT(cpu.esp == stack + 4 && cpu.ebx == 0x13245768 && cpu.edi == 0x87654321);
    }});
    controlsPending = false;
    requestedDrivingMode = DrivingMode::Keyboard; drivingModePending = true;
    win32::GamepadState state{}; state.axes[0] = 12000;
    setController(0, state);
    key(37, true);
    for (DrivingMode mode : {DrivingMode::Keyboard, DrivingMode::Tilt, DrivingMode::Controller, DrivingMode::Tilt, DrivingMode::Keyboard, DrivingMode::Tilt})
    {
        requestDrivingMode(DrivingMode::Controller); requestDrivingMode(mode);
        x86::CPU cpu{};
        NFS2_ASSERT(game.runThread(cpu, 0x400ffd) == 0);
        NFS2_ASSERT(drivingMode == mode && !drivingModePending);
        NFS2_ASSERT(controller(0).axes[0] == (mode != DrivingMode::Keyboard ? -32767 : 12000));
        key(38, true);
        NFS2_ASSERT(controller(0).axes[1] == (mode == DrivingMode::Controller ? -32767 : 0));
        uint8_t keyboard[256]{};
        keyboardState(keyboard, sizeof(keyboard));
        NFS2_ASSERT(keyboard[0x48] == 0x80);
        key(38, false); key(40, true);
        NFS2_ASSERT(controller(0).axes[1] == (mode == DrivingMode::Controller ? 32767 : 0));
        key(40, false);
        const uint32_t axisBindings[] = {0x0080ff01,0x007f0001,0x017f0001,0x0180ff01};
        for (unsigned offset : {0x16ccu, 0x1700u})
            for (unsigned index = 0; index < 13; ++index)
            {
                bool axis = (mode == DrivingMode::Controller && index < 4) || (mode == DrivingMode::Tilt && index < 2);
                uint32_t binding = axis ? axisBindings[index] : uint32_t(game.getMemory<uint32_t>(0x490430 + index * 4));
                memcpy(expected.data() + offset + index * 4, &binding, sizeof(binding));
            }
        auto live = expected;
        uint32_t steering = mode == DrivingMode::Keyboard ? 1 : 0;
        memcpy(live.data() + 0x6fd550 - 0x6fbb40, &steering, 4);
        for (unsigned index = 0; index < 3; ++index)
        {
            uint32_t value = mode == DrivingMode::Controller || (mode == DrivingMode::Tilt && index == 0) ? 0 : 1;
            memcpy(live.data() + 0x6fd2dc - 0x6fbb40 + index * 4, &value, 4);
            NFS2_ASSERT(game.getMemory<uint32_t>(0x6fd2dc + index * 4) == value);
        }
        NFS2_ASSERT(game.getMemory<uint32_t>(0x6fd52c + 0x24) == (mode == DrivingMode::Keyboard ? 1 : 0));
        NFS2_ASSERT(memcmp(&game.getMemory<uint8_t>(0x6fbb40), live.data(), live.size()) == 0);
        win32::File file("fedata\\config\\config.dat", win32::GENERIC_READ, 0, win32::OPEN_EXISTING);
        std::array<uint8_t, 0x20f0> saved{};
        uint32_t count = 0;
        NFS2_ASSERT(file.read(saved.data(), saved.size(), &count) && count == saved.size());
        NFS2_ASSERT(saved == expected);
    }
    key(37, false);
    { std::lock_guard<std::mutex> guard(messageMutex); messages.clear(); }
    game.registerMethod(0x400ffc, {"ResetControlsDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        for (unsigned context : {0u, 1u})
        {
            cpu.eax = context;
            cpu.esp -= 4;
            app->dynamic_call(0x4904f0, cpu);
        }
        cpu.esp += 4; cpu.eax = 0;
    }});
    game.registerMethod(0x400ffe, {"ActionKeyDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        unsigned action = app->getMemory<uint32_t>(cpu.esp + 4);
        win32::MSG message{};
        NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1);
        NFS2_ASSERT(message.message == 0x100 || message.message == 0x101);
        auto stack = cpu.esp;
        cpu.esp -= 28;
        app->getMemory<uint32_t>(cpu.esp + 4) = 1;
        app->getMemory<uint32_t>(cpu.esp + 8) = 0;
        app->getMemory<uint32_t>(cpu.esp + 12) = message.wParam;
        app->getMemory<uint32_t>(cpu.esp + 16) = 0;
        app->getMemory<uint32_t>(cpu.esp + 20) = message.lParam;
        app->getMemory<uint32_t>(cpu.esp + 24) = 0;
        app->dynamic_call(message.message == 0x100 ? 0x4cd020 : 0x4cd0e0, cpu);
        NFS2_ASSERT(cpu.esp == stack);
        cpu.eax = app->getMemory<uint32_t>(0x79c340 + action * 4);
        NFS2_ASSERT((cpu.eax & 0xff) == 4);
        cpu.esp -= 4;
        app->dynamic_call(app->getMemory<uint32_t>(0x554e44), cpu);
        cpu.esp += 4;
    }});
    for (unsigned context : {0u, 1u})
    {
        auto previous = expected;
        memcpy(previous.data(), &game.getMemory<uint8_t>(0x6fbb40), previous.size());
        memset(&game.getMemory<uint8_t>(0x6fc970), 0, 2 * 0x88);
        for (unsigned slot = 0; slot < 2; ++slot)
        {
            game.getMemory<uint32_t>(0x6fc970 + slot * 0x88) = 2;
            game.getMemory<uint32_t>(0x6fc9a8 + slot * 0x88) = 0x3ff;
            game.getMemory<uint32_t>(0x6fc9b0 + slot * 0x88) = 3;
        }
        x86::CPU reset{};
        NFS2_ASSERT(game.runThread(reset, 0x400ffc) == 0);
        std::array<uint32_t, 26> resetBindings{};
        memcpy(resetBindings.data(), &game.getMemory<uint8_t>(0x6fd20c), sizeof(resetBindings));
        for (unsigned table = 0; table < 2; ++table)
            NFS2_ASSERT((resetBindings[table * 13 + 5] & 0xff) == 2 && (resetBindings[table * 13 + 7] & 0xff) == 2);
        memcpy(&game.getMemory<uint8_t>(0x6fbb40), previous.data(), previous.size());
        memcpy(&game.getMemory<uint8_t>(0x6fd20c), resetBindings.data(), sizeof(resetBindings));
        game.getMemory<uint32_t>(0x6fd3b0) = context;
        NFS2_ASSERT(!drivingModePending);
        x86::CPU recovery{};
        NFS2_ASSERT(game.runThread(recovery, 0x400ffd) == 0 && drivingMode == DrivingMode::Tilt && !drivingModePending);
        NFS2_ASSERT(memcmp(&game.getMemory<uint8_t>(0x6fd20c), expected.data() + 0x16cc, 104) == 0);
        NFS2_ASSERT(memcmp(&game.getMemory<uint8_t>(0x6fd274), previous.data() + 0x1734, 52) == 0);
        const unsigned actionKeys[] = {32,'A','Z','C','H','B','R','S','L'};
        const unsigned actionIndices[] = {6,8,9,46,7,45,5,11,10};
        for (unsigned index = 0; index < 9; ++index)
        {
            NFS2_ASSERT(game.getMemory<uint32_t>(0x79c340 + actionIndices[index] * 4) == game.getMemory<uint32_t>(0x490440 + index * 4));
            key(actionKeys[index], true);
            x86::CPU press{};
            NFS2_ASSERT(game.runThread(press, 0x400ffe, actionIndices[index]) == 255);
            key(actionKeys[index], false);
            x86::CPU release{};
            NFS2_ASSERT(game.runThread(release, 0x400ffe, actionIndices[index]) == 0);
        }
        win32::File file("fedata\\config\\config.dat", win32::GENERIC_READ, 0, win32::OPEN_EXISTING);
        std::array<uint8_t, 0x20f0> saved{};
        uint32_t count = 0;
        NFS2_ASSERT(file.read(saved.data(), saved.size(), &count) && count == saved.size() && saved == expected);
    }
    game.getMemory<uint32_t>(0x6fd3b0) = 0;
    game.getMemory<uint32_t>(0x6fbb40) = 0;
    requestDrivingMode(DrivingMode::Keyboard);
    x86::CPU deferred{};
    NFS2_ASSERT(game.runThread(deferred, 0x400ffd) == 0 && drivingModePending && drivingMode == DrivingMode::Tilt);
    game.getMemory<uint32_t>(0x6fbb40) = 0x20f0;
    x86::CPU applied{};
    NFS2_ASSERT(game.runThread(applied, 0x400ffd) == 0 && drivingMode == DrivingMode::Keyboard && !drivingModePending);
    NFS2_ASSERT(win32::File::remove("fedata\\config\\config.dat") == 1);
    requestDrivingMode(DrivingMode::Tilt);
    x86::CPU missing{};
    NFS2_ASSERT(game.runThread(missing, 0x400ffd) == 0 && drivingMode == DrivingMode::Tilt && !drivingModePending);
    releaseInput(); installedControls = false;
    win32::platform::log("NFS3_DRIVING_PROFILE_DIAGNOSTIC: PASS original DirectInput poll refreshes steering/action caches and live car without pause; original device reset recovers in unchanged tilt mode; all nine virtual action keys reach original guest handlers and decoder in single/split player one; both tables persist, player two/other disk settings and CPU/stack stay intact; rapid toggles and deferred settings/file");
}
void gameInputDiagnostic()
{
    NFS2_ASSERT(!running);
    stopping = false;
    setRaceActive(false);
    {
        nfs3hp::Application game("nfs3.exe");
        const unsigned carKeys[] = {32,'A','Z','C','H','B','R','S','L'};
        for (unsigned index = 0; index < 9; ++index)
        {
            unsigned binding = game.getMemory<uint32_t>(0x490440 + index * 4);
            NFS2_ASSERT(binding == (4 | scanCode(carKeys[index]) << 8 | carKeys[index] << 24));
        }
        game.getMemory<uint32_t>(0x6fbb40) = 0x20f0;
        controlsPending = true;
        drivingMode = DrivingMode::Keyboard;
        updateGameState(&game);
        NFS2_ASSERT(!controlsPending && !inRace());
        for (unsigned index = 0; index < 13; ++index)
            NFS2_ASSERT(game.getMemory<uint32_t>(0x6fd240 + index * 4) == game.getMemory<uint32_t>(0x490430 + index * 4));
        drivingMode = DrivingMode::Tilt; controlsPending = true;
        updateGameState(&game);
        NFS2_ASSERT(game.getMemory<uint32_t>(0x6fd20c) == 0x0080ff01 && game.getMemory<uint32_t>(0x6fd274) == 0x1080ff01);
        for (unsigned index = 2; index < 4; ++index)
            NFS2_ASSERT(game.getMemory<uint32_t>(0x6fd20c + index * 4) == game.getMemory<uint32_t>(0x490430 + index * 4));
        win32::GamepadState pad{}; pad.axes[0] = 12000;
        setController(0, pad);
        key(37, true);
        NFS2_ASSERT(controller(0).axes[0] == -32767);
        key(37, false);
        NFS2_ASSERT(controller(0).axes[0] == 12000);
        drivingMode = DrivingMode::Keyboard;
        game.getMemory<int32_t>(0x5f38e0) = 0; game.getMemory<int32_t>(0x5f38e4) = 0;
        game.getMemory<int32_t>(0x5f38e8) = 639; game.getMemory<int32_t>(0x5f38ec) = 479;
        game.getMemory<int32_t>(0x5f38f0) = 12; game.getMemory<int32_t>(0x5f38f4) = 34;
        uint32_t records[3][4]{};
        pointer(0.5, 0.25, 1); pointer(0.5, 0.25, 0);
        updateGameState(&game);
        NFS2_ASSERT(readMouse(&game, records, 16, 1, true) == 1);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, true) == 3 && records[2][0] == 12 && records[2][1] == 0x80);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 3 && records[0][1] == 308 && records[1][1] == 86);
        game.getMemory<int32_t>(0x5f38f0) = 320; game.getMemory<int32_t>(0x5f38f4) = 120;
        updateGameState(&game);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 1 && records[0][0] == 12 && records[0][1] == 0);
        pointer(0.5, 0.25, 1);
        updateGameState(&game);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 1);
        releaseInput();
        updateGameState(&game);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 1 && records[0][1] == 0);
        game.getMemory<uint32_t>(0x7a3d10) = 0; game.getMemory<uint32_t>(0x6fd3a0) = 0;
        pointer(0.5, 0.25, 1);
        updateGameState(&game);
        setRaceActive(true);
        updateGameState(&game);
        NFS2_ASSERT(inRace());
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 2 && records[0][1] == 0x80 && records[1][1] == 0);
        uint8_t mouseState[16]{};
        readMouseState(mouseState, sizeof(mouseState));
        NFS2_ASSERT(mouseState[12] == 0);
        pointer(0.1, 0.2, 1);
        NFS2_ASSERT(readMouse(&game, records, 16, 3, false) == 0);
        game.getMemory<uint32_t>(0x7a3d10) = 1;
        updateGameState(&game);
        NFS2_ASSERT(!inRace());
        game.getMemory<uint32_t>(0x7a3d10) = 0;
        game.getMemory<uint32_t>(0x6fd3a0) = 2;
        updateGameState(&game);
        NFS2_ASSERT(!inRace());
        setRaceActive(false);
        game.getMemory<uint32_t>(0x6fd3a0) = 0;
        game.getMemory<uint8_t>(0x558b10) = 1; game.getMemory<uint32_t>(0x558b14) = 3;
        updateGameState(&game);
        NFS2_ASSERT(takingText());
        win32::platform::log("NFS3_POINTER_DIAGNOSTIC: PASS stock EXE bindings, menu/race/pause state, buffered tap/drag/release, peek and race touch suppression");
        auto signal = new win32::Event("ExitDiagnostic", false, false);
        uint32_t handle = game.allocateResource(signal);
        diagnosticWorkers = 0;
        game.registerMethod(0x400fff, {"ExitDiagnosticWait", [](win32::WinApplication* app, x86::CPU& cpu) {
            uint32_t handle = app->getMemory<uint32_t>(cpu.esp + 4);
            auto signal = dynamic_cast<win32::Event*>(app->getResource(handle));
            app->unlockContext(cpu);
            ++diagnosticWorkers;
            NFS2_ASSERT(win32::Event::wait(cpu, &signal, &signal + 1, false, -1) == uint32_t(-1));
            app->lockContext(cpu);
            cpu.esp += 4;
        }});
        game.allocateResource(new win32::Thread(&game, 0x400fff, handle, 0));
        game.allocateResource(new win32::Thread(&game, 0x400fff, handle, 4));
        for (unsigned delay : {1u, 60000u})
        {
            auto timer = new win32::Timer(delay, &game, 0x400fff, handle);
            game.allocateResource(timer);
            NFS2_ASSERT(timer->start());
        }
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (diagnosticWorkers < 2 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        NFS2_ASSERT(diagnosticWorkers == 2);
        x86::CPU exitCPU{};
        win32::kernel32::ExitProcess(&game, exitCPU, 0);
        NFS2_ASSERT(exitCPU.terminate);
        win32::platform::log("NFS3_EXIT_DIAGNOSTIC: cancelling event-blocked workers, suspended thread and timers before resource disposal");
    }
    driving = false; textEntry = false;
    releaseInput();
    { std::lock_guard<std::mutex> guard(messageMutex); messages.clear(); }
    win32::platform::log("NFS3_EXIT_DIAGNOSTIC: PASS worker/timer cleanup and guest memory released");
}
void timerDiagnostic()
{
    NFS2_ASSERT(!running && timerWorkersActive == 0);
    stopping = false;
    unsigned workers = timerWorkersCreated;
    TimerDiagnosticState state;
    {
        nfs3hp::Application game("nfs3.exe");
        timerDiagnosticState = &state;
        game.registerMethod(0x400f00, {"TimerDiagnosticFire", [](win32::WinApplication*, x86::CPU& cpu) {
            ++timerDiagnosticState.load()->fired;
            cpu.esp += 4;
        }});
        game.registerMethod(0x400f01, {"TimerDiagnosticSelfCancel", [](win32::WinApplication* app, x86::CPU& cpu) {
            win32::winmm::timeKillEvent(app, cpu, timerDiagnosticState.load()->selfHandle);
            NFS2_ASSERT(!cpu.terminate);
            ++timerDiagnosticState.load()->fired;
            cpu.esp += 4;
        }});
        game.registerMethod(0x400f02, {"TimerDiagnosticBlocked", [](win32::WinApplication* app, x86::CPU& cpu) {
            uint32_t handle = app->getMemory<uint32_t>(cpu.esp + 4);
            auto signal = dynamic_cast<win32::Event*>(app->getResource(handle));
            app->unlockContext(cpu);
            ++timerDiagnosticState.load()->waiting;
            NFS2_ASSERT(win32::Event::wait(cpu, &signal, &signal + 1, false, -1) == uint32_t(-1));
            app->lockContext(cpu);
            NFS2_ASSERT(cpu.terminate);
            ++timerDiagnosticState.load()->cancelled;
            cpu.esp += 4;
        }});
        game.registerMethod(0x400f03, {"TimerDiagnosticAPI", [](win32::WinApplication* app, x86::CPU& cpu) {
            auto state = timerDiagnosticState.load();
            if (state->command == 2)
            {
                app->getMemory<uint32_t>(0x79c170) = 65536;
                app->getMemory<uint32_t>(0x79c174) = 1;
                app->getMemory<uint32_t>(0x79c178) = win32::timeGetTickCount();
                app->getMemory<uint32_t>(0x79c198) = 0;
                app->getMemory<uint32_t>(0x79c19c) = 1;
                app->getMemory<uint32_t>(0x79c17c) = 0;
                app->getMemory<uint32_t>(0x79c168) = 0;
                app->getMemory<uint32_t>(0x5652ac) = 0;
                state->result = win32::winmm::timeSetEvent(app, cpu, 1, 1, 0x48ed30, 0, 0);
            }
            else if (state->command == 3)
            {
                app->getMemory<uint32_t>(0x79c19c) = 0;
                state->handle = app->getMemory<uint32_t>(0x79c194);
                win32::winmm::timeKillEvent(app, cpu, state->handle);
            }
            else if (state->command == 1) win32::winmm::timeKillEvent(app, cpu, state->handle);
            else
            {
                state->result = win32::winmm::timeSetEvent(app, cpu, state->delay, 1, state->procedure, state->parameter, 0);
                if (state->procedure == 0x400f01) state->selfHandle = state->result;
            }
            cpu.esp += 4;
            cpu.eax = 1;
        }});
        auto invoke = [&] {
            x86::CPU cpu{};
            NFS2_ASSERT(game.runThread(cpu, 0x400f03) == 1);
        };
        auto arm = [&](unsigned delay, uint32_t procedure, uint32_t parameter = 0) {
            state.command = 0; state.delay = delay; state.procedure = procedure; state.parameter = parameter;
            invoke();
            return state.result;
        };
        auto kill = [&](uint32_t handle) { state.command = 1; state.handle = handle; invoke(); };
        auto awaitCount = [&](const std::atomic<unsigned>& count, unsigned expected) {
            auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (count < expected && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            NFS2_ASSERT(count == expected);
        };
        auto idle = [&] {
            auto scheduler = schedulerFor(&game, false);
            NFS2_ASSERT(scheduler);
            std::unique_lock<std::mutex> guard(scheduler->mutex);
            NFS2_ASSERT(scheduler->condition.wait_for(guard, std::chrono::seconds(2), [&] { return scheduler->timers.empty() && !scheduler->current; }));
        };
        failTimerWorker = true;
        NFS2_ASSERT(arm(1, 0x400f00) == 0);
        NFS2_ASSERT(timerWorkersCreated == workers && timerWorkersActive == 0);
        uint32_t delayed = arm(60000, 0x400f00);
        uint32_t quick = arm(1, 0x400f00);
        NFS2_ASSERT(delayed && quick);
        awaitCount(state.fired, 1);
        kill(delayed); kill(delayed); idle();
        NFS2_ASSERT(!game.getResource(delayed) && !game.getResource(quick));
        NFS2_ASSERT(arm(1, 0x400f01));
        awaitCount(state.fired, 2); idle();
        NFS2_ASSERT(!game.getResource(state.selfHandle));
        auto signal = new win32::Event("TimerCancellationDiagnostic", false, false);
        uint32_t event = game.allocateResource(signal);
        uint32_t blocked = arm(1, 0x400f02, event);
        awaitCount(state.waiting, 1);
        kill(blocked); idle();
        NFS2_ASSERT(state.cancelled == 1 && !game.getResource(blocked));
        uint64_t before = timerCallbacksCompleted;
        state.command = 2; invoke();
        uint32_t first = state.result;
        NFS2_ASSERT(first);
        auto scheduler = schedulerFor(&game, false);
        {
            std::unique_lock<std::mutex> guard(scheduler->mutex);
            NFS2_ASSERT(scheduler->condition.wait_for(guard, std::chrono::seconds(60), [&] { return timerCallbacksCompleted >= before + 12000; }));
        }
        state.command = 3; invoke(); idle();
        NFS2_ASSERT(state.handle >= first + 12000);
        for (uint32_t handle = first; handle <= state.handle; ++handle) NFS2_ASSERT(!game.getResource(handle));
        NFS2_ASSERT(timerWorkersCreated == workers + 1 && timerWorkersActive == 1);
        arm(60000, 0x400f00);
        arm(1, 0x400f02, event);
        awaitCount(state.waiting, 2);
        scheduler.reset();
    }
    NFS2_ASSERT(timerWorkersActive == 0 && state.cancelled == 2);
    timerDiagnosticState = nullptr;
    win32::platform::log("NFS3_TIMER_DIAGNOSTIC: PASS worker-creation failure returns zero and retries; early-deadline wakeup, pending/repeated/self/active cancellation; 12000 original 48ed30 rearms use one worker and retire every expired handle; shutdown stops active/pending timers and releases the worker");
}
}

namespace win32
{
uint64_t platform::guestNanoseconds()
{
    std::lock_guard<std::mutex> guard(activeMutex);
    return (active ? platform::nanoseconds() : pauseBegan) - pausedNanoseconds;
}
WindowClass::WindowClass(x86::reg32 procedure) : m_wndProc(procedure) { windowClass = this; }
WindowClass::~WindowClass() { if (windowClass == this) windowClass = nullptr; }
Window::Window(const char*, int, int, int, int) : m_window(nullptr) {}
Window::~Window() = default;
x86::reg32 Window::getMessageHandler() { return windowClass ? windowClass->m_wndProc : 0; }
x86::reg32 Window::postMessage(x86::reg32 window, x86::reg32 message, x86::reg32 parameter, x86::reg32 extra)
{
    MSG result{};
    result.hWindow = window;
    result.message = message;
    result.wParam = parameter;
    result.lParam = extra;
    {
        std::lock_guard<std::mutex> guard(messageMutex);
        if (message == 0x200 && !messages.empty() && messages.back().message == 0x200) messages.back() = result;
        else messages.push_back(result);
    }
    messageCondition.notify_all();
    return 1;
}
x86::reg32 Window::getMessage(const x86::CPU& cpu, MSG* result, Window*, x86::reg32, x86::reg32)
{
    std::unique_lock<std::mutex> guard(messageMutex);
    while (messages.empty() && !cpu.terminate && !stopping)
        messageCondition.wait_for(guard, std::chrono::milliseconds(50));
    if (cpu.terminate || stopping) { *result = {}; return 0; }
    *result = messages.front();
    messages.pop_front();
    return result->message != 0x12;
}
Mutex::Mutex(const char* name) : m_mutex(new std::recursive_mutex), m_name(name ? name : ""), m_owner(0), m_count(0) {}
Mutex::~Mutex() { delete static_cast<std::recursive_mutex*>(m_mutex); }
void Mutex::lock() { static_cast<std::recursive_mutex*>(m_mutex)->lock(); }
void Mutex::unlock() { static_cast<std::recursive_mutex*>(m_mutex)->unlock(); }

struct Thread::NativeThread : NativeService
{
    unsigned id = nextThread++;
};
Thread::Thread() : m_native(std::make_shared<NativeThread>()) {}
Thread::Thread(const Thread& other) : m_native(other.m_native) {}
Thread::Thread(WinApplication* app, x86::reg32 entry, x86::reg32 parameter, x86::reg32 flags)
    : m_native(std::make_shared<NativeThread>())
{
    auto state = m_native;
    registerService(state, app);
    state->resumed = !(flags & 4);
    state->worker = std::thread([state, app, entry, parameter] {
        ::threadId = state->id;
        { std::unique_lock<std::mutex> guard(state->mutex); state->condition.wait(guard, [state] { return state->resumed; }); }
        if (!state->cpu.terminate) app->runThread(state->cpu, entry, parameter);
    });
}
Thread::~Thread() { if (m_native.use_count() == 1) terminate(); }
void Thread::resume()
{
    { std::lock_guard<std::mutex> guard(m_native->mutex); m_native->resumed = true; }
    m_native->condition.notify_all();
}
void Thread::terminate()
{
    m_native->requestStop();
    Event::broadcastTerminate();
    nfsios::wakeMessages();
    m_native->join();
}
x86::reg32 Thread::threadId() const { return m_native->id; }
x86::reg32 Thread::currentThreadId() { return ::threadId; }
void Thread::sleep(x86::reg32 milliseconds) { std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds)); }

Timer::Timer(x86::reg32 delay, WinApplication* app, x86::reg32 procedure, x86::reg32 parameter)
    : m_app(app), m_callback(procedure), m_parameter(parameter), m_id(new std::shared_ptr<ScheduledTimer>(std::make_shared<ScheduledTimer>()))
{
    auto state = *static_cast<std::shared_ptr<ScheduledTimer>*>(m_id);
    state->app = app; state->procedure = procedure; state->parameter = parameter; state->delay = delay;
}
Timer::~Timer() { cancel(); }
bool Timer::start()
{
    auto state = *static_cast<std::shared_ptr<ScheduledTimer>*>(m_id);
    auto scheduler = schedulerFor(m_app, true);
    if (!scheduler) return false;
    state->scheduler = scheduler;
    state->handle = getResourceIndex();
    NFS2_ASSERT(state->handle);
    state->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(state->delay);
    {
        std::lock_guard<std::mutex> guard(scheduler->mutex);
        if (scheduler->cancelled) return false;
        NFS2_ASSERT(scheduler->timers.emplace(state->handle, state).second);
    }
    scheduler->condition.notify_all();
    return true;
}
void Timer::cancelEvent(WinApplication* app, x86::CPU& cpu, x86::reg32 handle)
{
    auto scheduler = schedulerFor(app, false);
    if (!scheduler) return;
    std::shared_ptr<ScheduledTimer> state;
    {
        std::lock_guard<std::mutex> guard(scheduler->mutex);
        auto found = scheduler->timers.find(handle);
        if (found != scheduler->timers.end()) state = found->second;
        else if (scheduler->current && scheduler->current->handle == handle) state = scheduler->current;
    }
    if (!state) return;
    cancelTimer(state, &cpu);
    app->freeResourceIfPresent(handle);
}
void Timer::cancel()
{
    if (!m_id) return;
    auto state = *static_cast<std::shared_ptr<ScheduledTimer>*>(m_id);
    cancelTimer(state, nullptr);
    delete static_cast<std::shared_ptr<ScheduledTimer>*>(m_id);
    m_id = nullptr;
}
x86::reg32 timeGetTickCount() { return platform::guestNanoseconds() / 1000000; }
void getSystemTime(SYSTEMTIME* result)
{
    time_t now = time(nullptr);
    tm value{};
    gmtime_r(&now, &value);
    *result = {};
    result->wYear = value.tm_year + 1900;
    result->wMonth = value.tm_mon + 1;
    result->wDay = value.tm_mday;
    result->wDayOfWeek = value.tm_wday;
    result->wHour = value.tm_hour;
    result->wMinute = value.tm_min;
    result->wSecond = value.tm_sec;
}
Event::Event(const char* name, bool manual, bool initial)
    : m_name(name ? name : ""), m_manualReset(manual), m_isSet(initial), m_pulse(false), m_id(nextEvent++) {}
Event::~Event() = default;
void Event::init() {}
void Event::fini() {}
void Event::broadcastTerminate() { eventCondition.notify_all(); }
void Event::set()
{
    { std::lock_guard<std::mutex> guard(eventMutex); m_isSet = true; m_pulse = false; }
    eventCondition.notify_all();
}
x86::reg32 Event::pulse()
{
    { std::lock_guard<std::mutex> guard(eventMutex); m_isSet = !m_waitingThreads.empty(); m_pulse = true; }
    eventCondition.notify_all();
    return 1;
}
x86::reg32 Event::wait(x86::CPU& cpu, Event** begin, Event** end, bool waitAll, x86::sreg32 timeout)
{
    std::unique_lock<std::mutex> guard(eventMutex);
    for (auto current = begin; current != end; ++current) (*current)->m_waitingThreads.push_back(Thread::currentThreadId());
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::max(timeout, 0));
    x86::reg32 result = 0x102;
    for (;;)
    {
        bool all = std::all_of(begin, end, [](Event* event) { return event->m_isSet; });
        auto ready = std::find_if(begin, end, [](Event* event) { return event->m_isSet; });
        if ((waitAll && all) || (!waitAll && ready != end))
        {
            result = waitAll ? 0 : x86::reg32(ready - begin);
            if (waitAll) { for (auto current = begin; current != end; ++current) if (!(*current)->m_manualReset) (*current)->m_isSet = false; }
            else if (!(*ready)->m_manualReset) (*ready)->m_isSet = false;
            break;
        }
        if (cpu.terminate || stopping) { result = x86::reg32(-1); break; }
        if (timeout >= 0 && std::chrono::steady_clock::now() >= deadline) break;
        eventCondition.wait_for(guard, std::chrono::milliseconds(10));
    }
    for (auto current = begin; current != end; ++current)
    {
        auto& waiters = (*current)->m_waitingThreads;
        waiters.erase(std::remove(waiters.begin(), waiters.end(), Thread::currentThreadId()), waiters.end());
        if ((*current)->m_pulse && waiters.empty()) (*current)->m_isSet = false;
    }
    return result;
}
void Input::poll() {}
x86::reg32 Input::getButtonCount() const { return dynamic_cast<const Mouse*>(this) ? 4 : 0; }
x86::reg32 Input::getAxesCount() const { return dynamic_cast<const Mouse*>(this) ? 3 : 0; }
Gamepad::Gamepad(x86::reg32 index) : m_index(index) {}
Gamepad::~Gamepad() { nfsios::detachForceFeedback(this); }
x86::reg32 Gamepad::getCount() { return 2; }
x86::reg32 Gamepad::getButtonCount() const { return 16; }
x86::reg32 Gamepad::getAxesCount() const { return 6; }
GamepadState Gamepad::getState() const { return nfsios::controller(m_index); }
void Gamepad::updateKeys() {}
}
