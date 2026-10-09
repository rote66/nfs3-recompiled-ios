#include "ForceFeedback.h"
#include "Native.h"
#include <nfs3hp.h>
#include <winapi/dinput/idirectinput2.h>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>

namespace nfsios
{
namespace
{
uint32_t invoke(nfs3hp::Application& game, uint32_t object, unsigned slot, std::initializer_list<uint32_t> arguments)
{
    win32::MemMap stack(4096);
    x86::CPU cpu{};
    cpu.esp = stack.getBlockStart() + 3000;
    auto entryStack = cpu.esp;
    game.getMemory<uint32_t>(cpu.esp + 4) = object;
    unsigned offset = 8;
    for (uint32_t value : arguments) { game.getMemory<uint32_t>(cpu.esp + offset) = value; offset += 4; }
    game.dynamic_call(game.getMemory<uint32_t>(game.getMemory<uint32_t>(object) + slot * 4), cpu);
    NFS2_ASSERT(!cpu.terminate && cpu.esp == entryStack + offset);
    return cpu.eax;
}
}
void forceFeedbackDiagnostic()
{
    NFS2_ASSERT(!isRunning());
    setActive(true);
    {
        nfs3hp::Application game("nfs3.exe");
        auto input = win32::com::ComAlloc(&game);
        new (&game.getMemory<win32::dinput::IDirectInput2>(input)) win32::dinput::IDirectInput2;
        game.getMemory<uint32_t>(0x554ee4) = input;
        game.getMemory<uint32_t>(0x554ef8) = 0;
        game.getMemory<uint32_t>(0x554f00) = 0;
        game.getMemory<uint32_t>(0x9f3d24) = 1;
        game.getMemory<win32::GUID>(0x56b918) = {0x5944e682,0xc92e,0x11cf,{0xbf,0xc7,0x44,0x45,0x53,0x54,0,0}};
        x86::CPU enumeration{};
        NFS2_ASSERT(game.runThread(enumeration, 0x435600) == 2);
        for (unsigned slot = 0; slot < 2; ++slot)
        {
            uint32_t descriptor = 0x5f1ff8 + slot * 0x88;
            NFS2_ASSERT((game.getMemory<uint32_t>(descriptor) & 8) != 0);
            memcpy(&game.getMemory<uint8_t>(0x6fc970 + slot * 0x88), &game.getMemory<uint8_t>(descriptor), 0x88);
            game.getMemory<uint32_t>(0x6fc9b4 + slot * 0x88) = 100;
        }
        game.getMemory<uint32_t>(0x6fd204) = 2;
        game.getMemory<uint32_t>(0x6fd208) = 2;
        x86::CPU setup{};
        game.runThread(setup, 0x470dc0);
        std::array<uint32_t, 4> created{};
        win32::MemMap data(4096);
        for (unsigned index = 0; index < 4; ++index)
        {
            int16_t effect = game.getMemory<uint16_t>(0x678b60 + index * 2);
            NFS2_ASSERT(effect >= 0);
            created[index] = game.getMemory<uint32_t>(0x5f2878 + effect * 4);
            NFS2_ASSERT(created[index] && invoke(game, created[index], 4, {data.getBlockStart()}) == 0);
            win32::GUID guid = game.getMemory<win32::GUID>(data.getBlockStart());
            win32::platform::log("NFS3_FORCE_FEEDBACK_DIAGNOSTIC: original effect=%u GUID=%08x", index, guid.Data1);
        }
        for (unsigned index = 0; index < 13; ++index) game.getMemory<uint32_t>(0x6fd20c + index * 4) = game.getMemory<uint32_t>(0x490430 + index * 4);
        game.getMemory<uint32_t>(0x6fd3b0) = 0;
        game.getMemory<uint32_t>(0x6fd4f8) = 0;
        game.getMemory<uint32_t>(0x5efa48) = data.getBlockStart() + 2048;
        x86::CPU target{};
        game.runThread(target, 0x4710f0);
        NFS2_ASSERT(target.eax == data.getBlockStart() + 2048);
        auto collision = [&] {
            win32::MemMap stack(4096);
            x86::CPU cpu{};
            cpu.esp = stack.getBlockStart() + 3000;
            cpu.eax = data.getBlockStart() + 1280; cpu.edx = cpu.eax + 4; cpu.ebx = cpu.eax + 8;
            game.getMemory<uint32_t>(cpu.eax) = 90;
            game.getMemory<uint32_t>(cpu.edx) = 160;
            game.getMemory<uint32_t>(cpu.ebx) = 10000;
            game.getMemory<uint32_t>(0x6fd1f0) = 100;
            game.getMemory<uint32_t>(0x5efe00) += 100;
            game.dynamic_call(0x471fd0, cpu);
            NFS2_ASSERT(!cpu.terminate);
        };
        collision();
        NFS2_ASSERT(forceFeedbackFrame(0).impact > 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        NFS2_ASSERT(forceFeedbackFrame(0).impact == 0);
        collision();
        NFS2_ASSERT(forceFeedbackFrame(0).impact > 0);
        NFS2_ASSERT(invoke(game, created[0], 8, {}) == 0);
        NFS2_ASSERT(invoke(game, created[3], 7, {UINT32_MAX,0}) == 0 && forceFeedbackFrame(0).intensity == 0);
        auto constantGuid = win32::GUID{0x13541c20,0x8e33,0x11d0,{0x9a,0xd0,0,0xa0,0xc9,0xa0,0x6e,0x35}};
        auto device = uint32_t(game.getMemory<uint32_t>(0x5f1fb8));
        auto secondDevice = uint32_t(game.getMemory<uint32_t>(0x5f1fbc));
        game.registerMethod(0x400e90, {"ForceEffectEnumerationDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            uint32_t address = app->getMemory<uint32_t>(cpu.esp + 4);
            uint32_t user = app->getMemory<uint32_t>(cpu.esp + 8);
            win32::dinput::IDirectInputDevice::DIEffectInfo info = app->getMemory<win32::dinput::IDirectInputDevice::DIEffectInfo>(address);
            NFS2_ASSERT(info.dwSize == sizeof(info) && info.dwEffType == 3);
            app->getMemory<uint32_t>(user) += 1;
            cpu.esp += 12; cpu.eax = 1;
        }});
        game.getMemory<uint32_t>(data.getBlockStart() + 1536) = 0;
        NFS2_ASSERT(invoke(game, device, 19, {0x400e90,data.getBlockStart() + 1536,3}) == 0);
        NFS2_ASSERT(game.getMemory<uint32_t>(data.getBlockStart() + 1536) == 5);
        auto& parameters = *(&game.getMemory<win32::dinput::IDirectInputDevice::DIEFFECT>(data.getBlockStart()));
        memset(&parameters, 0, sizeof(parameters));
        parameters.dwSize = 56; parameters.dwDuration = 200000; parameters.dwGain = 10000;
        parameters.dwTriggerButton = UINT32_MAX; parameters.cbTypeSpecificParams = 4;
        parameters.lpvTypeSpecificParams = win32::Packed<void>(data.getBlockStart() + 256);
        game.getMemory<int32_t>(data.getBlockStart() + 256) = 8000;
        game.getMemory<win32::GUID>(data.getBlockStart() + 512) = constantGuid;
        auto create = [&](uint32_t selected) {
            NFS2_ASSERT(invoke(game, selected, 18, {data.getBlockStart() + 512, data.getBlockStart(), data.getBlockStart() + 768, 0}) == 0);
            return uint32_t(game.getMemory<uint32_t>(data.getBlockStart() + 768));
        };
        auto effect = create(device);
        NFS2_ASSERT(invoke(game, effect, 7, {1,0}) == 0);
        game.getMemory<int32_t>(data.getBlockStart() + 256) = 0;
        auto hit = forceFeedbackFrame(0);
        NFS2_ASSERT(hit.impact > 0.7 && forceFeedbackFrame(1).intensity == 0);
        game.getMemory<int32_t>(data.getBlockStart() + 256) = 8000;
        std::this_thread::sleep_for(std::chrono::milliseconds(220));
        NFS2_ASSERT(forceFeedbackFrame(0).impact == 0);
        NFS2_ASSERT(invoke(game, effect, 6, {data.getBlockStart(), 0x101}) == 0);
        NFS2_ASSERT(forceFeedbackFrame(0).impact > 0.7);
        NFS2_ASSERT(invoke(game, device, 22, {4}) == 0 && forceFeedbackFrame(0).intensity == 0);
        NFS2_ASSERT(invoke(game, device, 22, {8}) == 0 && forceFeedbackFrame(0).impact > 0.5);
        NFS2_ASSERT(invoke(game, device, 22, {32}) == 0 && forceFeedbackFrame(0).intensity == 0);
        NFS2_ASSERT(invoke(game, device, 22, {16}) == 0);
        auto& property = *(&game.getMemory<uint32_t>(data.getBlockStart() + 1024));
        uint32_t propertyValues[] = {20,16,0,0,0};
        memcpy(&property, propertyValues, sizeof(propertyValues));
        NFS2_ASSERT(invoke(game, device, 6, {12,data.getBlockStart() + 1024}) == 0 && forceFeedbackFrame(0).intensity == 0);
        game.getMemory<uint32_t>(data.getBlockStart() + 1040) = 5000;
        NFS2_ASSERT(invoke(game, device, 6, {12,data.getBlockStart() + 1024}) == 0);
        NFS2_ASSERT(invoke(game, effect, 7, {1,0}) == 0);
        NFS2_ASSERT(forceFeedbackFrame(0).impact > 0.3f && forceFeedbackFrame(0).impact <= 0.401f);
        NFS2_ASSERT(invoke(game, device, 5, {12,data.getBlockStart() + 1024}) == 0 && game.getMemory<uint32_t>(data.getBlockStart() + 1040) == 5000);
        NFS2_ASSERT(invoke(game, effect, 8, {}) == 0 && forceFeedbackFrame(0).impact == 0);
        auto second = create(secondDevice);
        NFS2_ASSERT(invoke(game, second, 7, {1,0}) == 0);
        NFS2_ASSERT(forceFeedbackFrame(0).intensity == 0 && forceFeedbackFrame(1).impact > 0.7);
        NFS2_ASSERT(invoke(game, second, 2, {}) == 0 && forceFeedbackFrame(1).intensity == 0);
        parameters.dwGain = 10001;
        NFS2_ASSERT(invoke(game, effect, 6, {data.getBlockStart(),4}) == 0x80070057);
        NFS2_ASSERT(invoke(game, effect, 2, {}) == 0);
        parameters.dwGain = 10000; parameters.dwDuration = UINT32_MAX; parameters.cbTypeSpecificParams = 16;
        int32_t periodic[] = {8000,0,0,33333};
        memcpy(&game.getMemory<int32_t>(data.getBlockStart() + 256), periodic, sizeof(periodic));
        for (unsigned index : {1u,2u})
        {
            NFS2_ASSERT(invoke(game, created[index], 6, {data.getBlockStart(),0x105}) == 0);
            NFS2_ASSERT(invoke(game, created[index], 7, {UINT32_MAX,0}) == 0);
        }
        auto textures = forceFeedbackFrame(0);
        NFS2_ASSERT(textures.road > 0.39 && textures.engine > 0.39 && std::abs(textures.engineHz - 30) < 0.1);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        NFS2_ASSERT(std::abs(forceFeedbackFrame(0).intensity - textures.intensity) < 0.001);
        for (auto object : created) NFS2_ASSERT(invoke(game, object, 2, {}) == 0);
    }
    NFS2_ASSERT(forceFeedbackFrame(0).intensity == 0 && forceFeedbackFrame(1).intensity == 0);
    win32::platform::log("NFS3_FORCE_FEEDBACK_DIAGNOSTIC: PASS original controller capability/metadata and four-effect initialization, keyboard player selection, original repeated collision path and decay, effect enumeration/filter/callback ABI, deep-copy COM parameters, start/stop/pause/actuators/gain, per-player isolation, steady road/engine peak with RPM, silent spring, validation and cleanup");
}
}
