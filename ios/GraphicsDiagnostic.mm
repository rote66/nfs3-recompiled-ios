#import <Foundation/Foundation.h>
#include "Native.h"
#include <nfs3hp.h>
#include <lib/renderer.h>
#include <lib/gliderenderer.h>
#include <lib/mutex.h>
#include <lib/window.h>
#include <winapi/user32.h>
#include <array>
#include <initializer_list>
#include <atomic>
#include <condition_variable>
#include <thread>

namespace
{
struct GraphicsRaceState
{
    std::mutex mutex;
    std::condition_variable condition;
    bool frameReached = false;
    bool settingsAttempted = false;
    std::atomic<bool> frameActive{false};
    std::atomic<bool> renderActive{false};
    std::atomic<bool> settingsEntered{false};
    unsigned frames = 0;
    unsigned messages = 0;
};
std::atomic<GraphicsRaceState*> graphicsRace{nullptr};
uint32_t threadCall(win32::WinApplication* app, x86::CPU& cpu, uint32_t address, std::initializer_list<uint32_t> arguments)
{
    uint32_t top = cpu.esp;
    cpu.esp -= 4 * (arguments.size() + 1);
    app->getMemory<uint32_t>(cpu.esp) = 0;
    unsigned index = 0;
    for (uint32_t argument : arguments) app->getMemory<uint32_t>(cpu.esp + 4 * ++index) = argument;
    app->dynamic_call(address, cpu);
    NFS2_ASSERT(!cpu.terminate && cpu.esp == top);
    return cpu.eax;
}
}

namespace nfsios
{
void graphicsConcurrencyDiagnostic()
{
    @autoreleasepool
    {
        nfs3hp::Application game("nfs3.exe");
        win32::WindowClass windowClass(0x400ff4);
        uint32_t window = game.allocateResource(new win32::Window("NFS3", 0, 0, 640, 480));
        game.registerMethod(0x400ff4, {"PauseMessageDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            auto state = graphicsRace.load();
            NFS2_ASSERT(state->frameActive && !state->renderActive);
            NFS2_ASSERT(app->getMemory<uint32_t>(cpu.esp + 8) == 0x201);
            ++state->messages;
            cpu.esp += 20;
            cpu.eax = 0;
        }});
        game.registerMethod(0x400ff5, {"GraphicsSetupDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            uint32_t window = app->getMemory<uint32_t>(cpu.esp + 4);
            NFS2_ASSERT(threadCall(app, cpu, 0xa83f50, {}) != 0);
            app->getMemory<uint32_t>(0xa91f08) = window;
            NFS2_ASSERT(threadCall(app, cpu, 0xa843d0, {1, 2, 1}) != 0);
            threadCall(app, cpu, 0xa84780, {2});
            cpu.esp += 4;
            cpu.eax = 1;
        }});
        game.registerMethod(0x400ff6, {"GraphicsFrameDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            auto state = graphicsRace.load();
            state->frameActive = true;
            for (; state->frames < 60 && !state->settingsEntered; ++state->frames)
            {
                threadCall(app, cpu, 0xa847b0, {});
                threadCall(app, cpu, 0xa847e0, {});
            }
            if (!state->settingsEntered) win32::platform::log("NFS3_GRAPHICS_SCHEDULING_ERROR: paused window-message thread blocked for sixty frames inside one guest runThread");
            NFS2_ASSERT(state->settingsEntered && state->messages == 1 && state->frames < 60);
            state->frameActive = false;
            cpu.esp += 4;
            cpu.eax = 1;
        }});
        game.registerMethod(0x400ff7, {"GraphicsSettingsDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            auto state = graphicsRace.load();
            if (state->renderActive) win32::platform::log("NFS3_GRAPHICS_CONCURRENCY_ERROR: settings thread entered during native rendering");
            NFS2_ASSERT(state->frameActive && !state->renderActive);
            win32::MSG message{};
            message.hWindow = app->getMemory<uint32_t>(0xa91f08);
            message.message = 0x201;
            message.wParam = 1;
            message.lParam = 280u << 16 | 413u;
            win32::user32::DispatchMessageA(app, cpu, &message);
            NFS2_ASSERT(!cpu.terminate);
            uint32_t mode = app->getMemory<uint32_t>(cpu.esp + 4);
            NFS2_ASSERT(threadCall(app, cpu, 0xa843d0, {mode, 2, 1}) != 0);
            threadCall(app, cpu, 0xa84780, {2});
            threadCall(app, cpu, 0xa847b0, {});
            threadCall(app, cpu, 0xa847e0, {});
            state->settingsEntered = true;
            state->condition.notify_all();
            cpu.esp += 4;
            cpu.eax = 1;
        }});
        game.registerMethod(0x400ff8, {"GraphicsShutdownDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
            threadCall(app, cpu, 0xa84100, {});
            cpu.esp += 4;
            cpu.eax = 1;
        }});
        x86::CPU setup{};
        NFS2_ASSERT(game.runThread(setup, 0x400ff5, window) == 1);
        for (unsigned iteration = 0; iteration < 12; ++iteration)
        {
            GraphicsRaceState state;
            graphicsRace = &state;
            setRenderDiagnosticHook([](void* context, bool rendering) {
                auto state = static_cast<GraphicsRaceState*>(context);
                state->renderActive = rendering;
                if (!rendering) return;
                std::unique_lock<std::mutex> guard(state->mutex);
                if (state->frameReached) return;
                state->frameReached = true;
                state->condition.notify_all();
                NFS2_ASSERT(state->condition.wait_for(guard, std::chrono::seconds(2), [&] { return state->settingsAttempted; }));
                state->condition.wait_for(guard, std::chrono::milliseconds(100), [&] { return bool(state->settingsEntered); });
                NFS2_ASSERT(!state->settingsEntered);
            }, &state);
            std::thread frame([&] {
                x86::CPU cpu{};
                NFS2_ASSERT(game.runThread(cpu, 0x400ff6) == 1);
            });
            {
                std::unique_lock<std::mutex> guard(state.mutex);
                NFS2_ASSERT(state.condition.wait_for(guard, std::chrono::seconds(2), [&] { return state.frameReached; }));
            }
            uint32_t mode = std::array<uint32_t, 3>{2, 13, 1}[iteration % 3];
            std::thread settings([&] {
                { std::lock_guard<std::mutex> guard(state.mutex); state.settingsAttempted = true; }
                state.condition.notify_all();
                x86::CPU cpu{};
                NFS2_ASSERT(game.runThread(cpu, 0x400ff7, mode) == 1);
            });
            frame.join(); settings.join();
            NFS2_ASSERT(state.settingsEntered && !state.frameActive);
            setRenderDiagnosticHook(nullptr, nullptr);
            win32::MemMap memory(64 * 1024);
            x86::CPU resumed{};
            resumed.esp = memory.getBlockStart() + memory.getBlockSize();
            win32::Mutex mutex("ResumedGraphicsDiagnostic");
            resumed.efs = memory.getBlockStart();
            game.getMemory<win32::Mutex*>(resumed.efs + 8) = &mutex;
            win32::LockContext guard(game, resumed);
            threadCall(&game, resumed, 0xa847b0, {});
            threadCall(&game, resumed, 0xa847e0, {});
            double width, height;
            presentationSize(width, height);
            NFS2_ASSERT(width == (mode == 2 ? 800 : mode == 13 ? 1024 : 640));
            NFS2_ASSERT(height == (mode == 2 ? 600 : mode == 13 ? 768 : 480));
        }
        graphicsRace = nullptr;
        x86::CPU shutdown{};
        NFS2_ASSERT(game.runThread(shutdown, 0x400ff8) == 1);
        win32::platform::log("NFS3_GRAPHICS_CONCURRENCY_DIAGNOSTIC: PASS twelve continuous guest frame loops; paused mouse messages and driver close/reopen execute before the loop returns, only after native rendering; rendering resumes at 640x480, 800x600 and 1024x768");
    }
}
void graphicsIntegrationDiagnostic()
{
    @autoreleasepool
    {
        nfs3hp::Application game("nfs3.exe");
        {
            win32::Renderer renderer(&game, nullptr);
            renderer.setVideoMode(640, 480, 16);
            win32::GlideRenderer glide(&renderer);
            auto quad = [&](float horizontal, float vertical, float width, float height, float depth, uint32_t color, float textureS = 0, float textureT = 0, float alpha = 255) {
                win32::GrVertex vertices[4]{};
                const float positions[4][2] = {{horizontal, vertical}, {horizontal + width, vertical}, {horizontal + width, vertical + height}, {horizontal, vertical + height}};
                for (unsigned index = 0; index < 4; ++index)
                {
                    auto& vertex = vertices[index];
                    vertex.x = positions[index][0]; vertex.y = positions[index][1];
                    vertex.ooz = depth; vertex.oow = 1;
                    vertex.r = (color >> 16) & 255; vertex.g = (color >> 8) & 255; vertex.b = color & 255;
                    vertex.a = alpha;
                    vertex.tmuvtx[0].sow = textureS * 256; vertex.tmuvtx[0].tow = textureT * 256;
                }
                glide.drawTriangle(&vertices[0], &vertices[1], &vertices[2]);
                glide.drawTriangle(&vertices[0], &vertices[2], &vertices[3]);
            };
            glide.setColorFactor(0); glide.setAlphaFactor(0);
            glide.clear(0);
            quad(0, 0, 640, 480, 65000, 0x204080);
            quad(120, 200, 400, 250, 30000, 0x808080);
            quad(220, 240, 80, 80, 10000, 0xff0000);
            quad(240, 260, 80, 80, 20000, 0x00ff00);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(250, 280) == 0xff0000ff);
            NFS2_ASSERT(renderer.diagnosticPixel(310, 280) == 0xff00ff00);
            NFS2_ASSERT(renderer.diagnosticPixel(150, 300) == 0xff808080);
            NFS2_ASSERT(renderer.diagnosticPixel(10, 10) == 0xff804020);
            quad(220, 240, 80, 80, 20000, 0x0000ff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(250, 280) == 0xff0000ff);
            glide.setZTest(false);
            quad(220, 240, 80, 80, 65000, 0xffffff);
            glide.setZTest(true);
            quad(220, 240, 80, 80, 20000, 0x0000ff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(250, 280) == 0xffff0000);
            glide.clear(0);
            glide.setZWrite(false);
            quad(0, 0, 640, 480, 500, 0xff0000);
            glide.setZWrite(true);
            quad(220, 240, 80, 80, 20000, 0x0000ff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(250, 280) == 0xffff0000);
            uint16_t red = 0xfc00;
            uint16_t green = 0x83e0;
            glide.clear(0);
            glide.setColorFactor(1); glide.setAlphaFactor(1);
            glide.setTextureData(0, 8, &red, 8, 8, win32::TF_ARGB_1555);
            glide.setTexture(0, 8);
            quad(100, 100, 100, 100, 20000, 0xffffff);
            glide.setTextureData(0, 8, &green, 8, 8, win32::TF_ARGB_1555);
            quad(300, 100, 100, 100, 20000, 0xffffff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff0000ff);
            NFS2_ASSERT(renderer.diagnosticPixel(350, 150) == 0xff00ff00);
            for (auto size : {std::array<unsigned, 2>{1024, 768}, {800, 600}, {640, 480}})
            {
                renderer.setVideoMode(size[0], size[1], 16);
                glide.swap();
                glide.clear(0);
                quad(100, 100, 100, 100, 20000, 0xffffff);
                glide.swap();
                NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff00ff00);
            }
            win32::platform::log("NFS3_RENDER_DIAGNOSTIC: PASS original depth order, car/road overlap, persistent depth, ALWAYS writes, depth mask, bound texture replacement and video-mode resize");
            glide.setColorFactor(0); glide.setAlphaFactor(0);
            glide.setClipWindow(0, 0, 640, 480);
            glide.clear(0);
            quad(0, 0, 640, 480, 30000, 0x204080);
            glide.setClipWindow(220, 60, 420, 120);
            glide.clear(0);
            quad(0, 0, 640, 480, 50000, 0x00ff00);
            quad(0, 100, 640, 2, 20000, 0);
            glide.swap();
            if (renderer.diagnosticPixel(320, 240) != 0xff804020)
                win32::platform::log("NFS3_CLIP_ERROR: inset clear/draw overwrote the forward scene outside the mirror");
            NFS2_ASSERT(renderer.diagnosticPixel(320, 240) == 0xff804020);
            NFS2_ASSERT(renderer.diagnosticPixel(320, 90) == 0xff00ff00);
            NFS2_ASSERT(renderer.diagnosticPixel(320, 100) == 0xff000000);
            NFS2_ASSERT(renderer.diagnosticPixel(100, 100) == 0xff804020);
            for (auto point : {std::array<unsigned, 2>{219, 90}, {420, 90}, {320, 59}, {320, 120}, {10, 10}})
                NFS2_ASSERT(renderer.diagnosticPixel(point[0], point[1]) == 0xff804020);
            glide.setClipWindow(0, 0, 640, 480);
            quad(0, 0, 640, 480, 40000, 0xff0000);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(320, 90) == 0xff0000ff);
            NFS2_ASSERT(renderer.diagnosticPixel(320, 240) == 0xff804020);
            glide.setClipWindow(100, 220, 120, 240);
            glide.setZTest(false);
            quad(0, 0, 640, 480, 65000, 0xffffff);
            glide.setZTest(true);
            glide.setClipWindow(90, 210, 130, 250);
            quad(0, 0, 640, 480, 40000, 0x0000ff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(110, 230) == 0xffff0000);
            NFS2_ASSERT(renderer.diagnosticPixel(95, 215) == 0xff804020);
            glide.setClipWindow(630, 470, 900, 900);
            glide.clear(0xffffff);
            glide.setClipWindow(400, 300, 200, 100);
            glide.clear(0);
            quad(0, 0, 640, 480, 0, 0);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(639, 479) == 0xffffffff);
            NFS2_ASSERT(renderer.diagnosticPixel(629, 469) == 0xff804020);
            glide.setClipWindow(0, 0, 640, 480);
            glide.clear(0);
            quad(0, 0, 640, 480, 50000, 0x00ff00);
            glide.clear(0);
            quad(220, 240, 80, 80, 20000, 0x0000ff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(250, 280) == 0xffff0000);
            NFS2_ASSERT(renderer.diagnosticPixel(10, 10) == 0xff000000);
            win32::platform::log("NFS3_CLIP_DIAGNOSTIC: PASS ordered forward-scene/mirror clear and draws, black border restricted to mirror, top-left clip orientation and edges, partial depth reset, retained outside depth, ALWAYS reset pass, clipped bounds and empty clips");
            glide.setZTest(false); glide.setZWrite(false);
            glide.setColorFactor(1); glide.setAlphaFactor(1);
            uint16_t corners[] = {0xf800, 0x07e0, 0x001f, 0xffff};
            glide.setTextureData(0, 16, corners, 7, 7, win32::TF_RGB_565);
            glide.setTexture(0, 16);
            glide.clear(0x204080);
            for (unsigned mode = 0; mode < 4; ++mode)
            {
                glide.setTextureClamp(mode & 1, mode & 2);
                quad(40 + mode * 140, 40, 100, 80, 1000, 0xffffff, 1.25f, 1.25f);
                quad(40 + mode * 140, 140, 100, 80, 1000, 0xffffff, -0.25f, -0.25f);
            }
            glide.swap();
            const uint32_t positive[] = {0xffffffff, 0xffff0000, 0xff00ff00, 0xff0000ff};
            const uint32_t negative[] = {0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff};
            for (unsigned mode = 0; mode < 4; ++mode)
            {
                NFS2_ASSERT(renderer.diagnosticPixel(90 + mode * 140, 80) == positive[mode]);
                NFS2_ASSERT(renderer.diagnosticPixel(90 + mode * 140, 180) == negative[mode]);
            }
            uint16_t keyed[] = {0, 0xf800, 0, 0xf800};
            glide.setTextureData(0, 16, keyed, 7, 7, win32::TF_RGB_565);
            glide.setTextureClamp(false, false);
            glide.clear(0x204080);
            glide.setChromakeyColor(0); glide.setChromakey(true);
            quad(40, 40, 100, 100, 1000, 0xffffff, 0.25f, 0.25f);
            quad(180, 40, 100, 100, 1000, 0xffffff, 0.5f, 0.25f);
            quad(320, 40, 100, 100, 1000, 0xffffff, 0.75f, 0.25f);
            glide.setChromakey(false);
            quad(460, 40, 100, 100, 1000, 0xffffff, 0.25f, 0.25f);
            glide.setChromakeyColor(0xff0000); glide.setChromakey(true);
            quad(40, 200, 100, 100, 1000, 0xffffff, 0.75f, 0.25f);
            quad(180, 200, 100, 100, 1000, 0xffffff, 0.25f, 0.25f);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(90, 90) == 0xff804020);
            NFS2_ASSERT(renderer.diagnosticPixel(230, 90) == 0xff0000ff);
            NFS2_ASSERT(renderer.diagnosticPixel(370, 90) == 0xff0000ff);
            NFS2_ASSERT(renderer.diagnosticPixel(510, 90) == 0xff000000);
            NFS2_ASSERT(renderer.diagnosticPixel(90, 250) == 0xff804020);
            NFS2_ASSERT(renderer.diagnosticPixel(230, 250) == 0xff000000);
            glide.setChromakey(false);
            glide.setColorFactor(0); glide.setAlphaFactor(0);
            glide.clear(0x204080);
            glide.setAlphaReference(128);
            quad(40, 40, 100, 100, 1000, 0xff0000, 0, 0, 128);
            glide.setAlphaReference(127);
            quad(180, 40, 100, 100, 1000, 0xff0000, 0, 0, 128);
            glide.setAlphaReference(255);
            quad(320, 40, 100, 100, 1000, 0xffffff);
            glide.setAlphaReference(0);
            quad(460, 40, 100, 100, 1000, 0xffffff);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(90, 90) == 0xff804020);
            uint32_t blended = renderer.diagnosticPixel(230, 90);
            NFS2_ASSERT((blended & 255) >= 142 && (blended & 255) <= 145);
            NFS2_ASSERT(((blended >> 8) & 255) >= 31 && ((blended >> 8) & 255) <= 33);
            NFS2_ASSERT(((blended >> 16) & 255) >= 63 && ((blended >> 16) & 255) <= 65);
            NFS2_ASSERT(renderer.diagnosticPixel(370, 90) == 0xff804020);
            NFS2_ASSERT(renderer.diagnosticPixel(510, 90) == 0xffffffff);
            win32::platform::log("NFS3_TEXTURE_DIAGNOSTIC: PASS per-axis positive/negative clamp and wrap, captured sampling changes, opaque RGB565 black/nonblack chromakey, prefilter key rejection without dark edge, dynamic GREATER alpha reference including equality");
        }
        win32::MemMap memory(64 * 1024);
        memset(&game.getMemory<uint8_t>(memory.getBlockStart()), 0, memory.getBlockSize());
        win32::Mutex mutex("GraphicsDiagnostic");
        x86::CPU cpu{};
        cpu.efs = memory.getBlockStart();
        game.getMemory<win32::Mutex*>(cpu.efs + 8) = &mutex;
        win32::LockContext guard(game, cpu);
        auto call = [&](uint32_t address, std::initializer_list<uint32_t> arguments) {
            uint32_t top = memory.getBlockStart() + memory.getBlockSize() - 256;
            cpu.esp = top - 4 * (arguments.size() + 1);
            game.getMemory<uint32_t>(cpu.esp) = 0;
            unsigned index = 0;
            for (uint32_t argument : arguments) game.getMemory<uint32_t>(cpu.esp + 4 * ++index) = argument;
            win32::platform::log("NFS3_GRAPHICS_DIAGNOSTIC: guest call %08x", address);
            game.dynamic_call(address, cpu);
            NFS2_ASSERT(!cpu.terminate && cpu.esp == top);
            return cpu.eax;
        };
        auto beginName = [&](const char* name, uint32_t selection = 0, uint32_t existing = 0) {
            game.getMemory<uint32_t>(0x559234) = 1;
            game.getMemory<uint8_t>(0x558b10) = 1;
            game.getMemory<uint32_t>(0x558b14) = 3;
            game.getMemory<uint32_t>(0x558b18) = 0x45cdd0;
            game.getMemory<uint32_t>(0x558b3c) = selection;
            game.getMemory<uint32_t>(0x664658) = existing;
            game.getMemory<uint32_t>(0x558b2c) = 0;
            game.getMemory<uint32_t>(0x558c5c) = 0;
            game.getMemory<uint32_t>(0x558b54) = 10;
            game.getMemory<uint32_t>(0x558b50) = strlen(name);
            memset(&game.getMemory<char>(0x558b58), 0, 256);
            strcpy(&game.getMemory<char>(0x558b58), name);
        };
        auto nameKey = [&](uint32_t key) { cpu.eax = key; NFS2_ASSERT(call(0x445e60, {}) == 0); };
        auto nameClosed = [&] {
            return game.getMemory<uint8_t>(0x558b10) == 0 && game.getMemory<uint32_t>(0x558b14) == 0 && game.getMemory<uint32_t>(0x558b18) == 0;
        };
        uint8_t lowByte = game.getMemory<uint8_t>(1);
        beginName("ROTE");
        nameKey(8); nameKey('_');
        NFS2_ASSERT(strcmp(&game.getMemory<char>(0x558b58), "ROT_") == 0);
        nameKey(13);
        NFS2_ASSERT(nameClosed() && strcmp(&game.getMemory<char>(0x6fd2fc), "ROT_") == 0);
        beginName("ABCDEFGHIJ"); nameKey('_');
        NFS2_ASSERT(game.getMemory<uint32_t>(0x558b50) == 10 && strcmp(&game.getMemory<char>(0x558b58), "ABCDEFGHIJ") == 0);
        nameKey(8); nameKey('_'); nameKey(13);
        NFS2_ASSERT(nameClosed() && strcmp(&game.getMemory<char>(0x6fd2fc), "ABCDEFGHI_") == 0);
        for (const char* invalid : {"", "ABCDEFGHIJK"})
        {
            beginName(invalid); nameKey(13);
            NFS2_ASSERT(!nameClosed() && game.getMemory<uint32_t>(0x558b18) == 0x45cdd0);
            NFS2_ASSERT(strcmp(&game.getMemory<char>(0x6fd2fc), "ABCDEFGHI_") == 0);
            nameKey(27); NFS2_ASSERT(nameClosed());
        }
        beginName("CANCEL"); nameKey(27);
        NFS2_ASSERT(nameClosed() && strcmp(&game.getMemory<char>(0x6fd2fc), "ABCDEFGHI_") == 0);
        beginName("ROTE", 1, 1); nameKey(13);
        NFS2_ASSERT(nameClosed() && strcmp(&game.getMemory<char>(0x6fd2fc), "ABCDEFGHI_") == 0);
        beginName("ROTE", 2, 1); nameKey(13);
        NFS2_ASSERT(!nameClosed()); nameKey(27); NFS2_ASSERT(nameClosed());
        NFS2_ASSERT(game.getMemory<uint8_t>(1) == lowByte);
        win32::platform::log("NFS3_NAME_DIAGNOSTIC: PASS original text-input dispatch to 0045cdd0; typing/deletion/length limit, confirmation saves name, invalid names keep prompt, Cancel and existing-name selection preserve name, guest stack balanced and padding does not alter low memory");
        NFS2_ASSERT(call(0x49f810, {}) == 0);
        uint32_t menu = memory.getBlockStart() + 640;
        uint32_t label = memory.getBlockStart() + 1024;
        strcpy(&game.getMemory<char>(label), "CAR_DOWNLOAD");
        game.getMemory<uint32_t>(0x552594) = 0;
        for (uint32_t first : {0u, 4u})
        {
            memset(&game.getMemory<uint8_t>(0x604ee0), 0, 8 * 188);
            memset(&game.getMemory<uint8_t>(menu), 0, 188);
            game.getMemory<uint32_t>(menu + 0x16) = first << 16;
            uint32_t item = 0x604ee0 + first * 188;
            game.getMemory<uint32_t>(item) = 5;
            game.getMemory<uint32_t>(item + 16) = label;
            game.getMemory<uint8_t>(item + 5) = 0x02;
            cpu.eax = menu; call(0x426d60, {});
            NFS2_ASSERT(game.getMemory<uint8_t>(item + 5) == 0x12);
            NFS2_ASSERT(game.getMemory<uint32_t>(item + 0x64) == 0);
        }
        win32::platform::log("NFS3_DOWNLOAD_DIAGNOSTIC: PASS original network probe returns unavailable without an assertion; car-menu setup hides CAR_DOWNLOAD with original draw/focus flag in two menu instances, preserves other flags and does not install download callback");
        call(0x4df740, {});
        win32::MemMap pool(2 * 1024 * 1024);
        call(0x4e1100, {});
        cpu.eax = pool.getBlockStart(); cpu.edx = pool.getBlockSize();
        call(0x4f9270, {});
        NFS2_ASSERT(game.getMemory<uint32_t>(0x9ef5c0) != 0);
        for (unsigned iteration = 0; iteration < 3; ++iteration)
        {
            cpu.eax = 3;
            NFS2_ASSERT(call(0x49e360, {}) == 0);
            NFS2_ASSERT(game.getMemory<uint32_t>(0x55e718) == 0 && game.getMemory<uint32_t>(0x566e84) == 0);
            NFS2_ASSERT(game.getMemory<uint32_t>(0x9f3650) == 0);
            NFS2_ASSERT(call(0x533e38, {}) == 10047);
        }
        memset(&game.getMemory<uint8_t>(0x604ee0), 0, 8 * 188);
        memset(&game.getMemory<uint8_t>(menu), 0, 188);
        for (unsigned index = 0; index < 2; ++index)
        {
            uint32_t item = 0x604ee0 + index * 188;
            game.getMemory<uint32_t>(item) = 5;
            game.getMemory<uint32_t>(item + 16) = index ? 0x537900 : 0x5378f8;
        }
        cpu.eax = menu;
        NFS2_ASSERT(call(0x4405c0, {}) == 0);
        for (unsigned index = 0; index < 2; ++index)
            NFS2_ASSERT((game.getMemory<uint8_t>(0x604ee0 + index * 188 + 4) & 1) != 0);
        win32::platform::log("NFS3_CONNECT_DIAGNOSTIC: PASS repeated original Connect Players protocol discovery and menu setup, unsupported IPX socket returns unavailable/10047, failed transport cleans up without worker and unavailable protocol choices are disabled by original game");
        uint32_t window = game.allocateResource(new win32::Window("NFS3", 0, 0, 640, 480));
        NFS2_ASSERT(call(0xa83f50, {}) != 0);
        game.getMemory<uint32_t>(0xa91f08) = window;
        for (uint32_t mode : {1u, 2u, 13u, 1u})
        {
            NFS2_ASSERT(call(0xa843d0, {mode, 2, 1}) != 0);
            call(0xa84780, {2});
            call(0xa847b0, {});
            call(0xa847e0, {});
        }
        uint32_t event = memory.getBlockStart() + 256;
        uint32_t action = memory.getBlockStart() + 320;
        game.getMemory<uint32_t>(0x604ee0) = 5;
        game.getMemory<uint32_t>(0x604ef0) = action;
        memcpy(&game.getMemory<uint8_t>(0x662ca0), &game.getMemory<uint8_t>(0x6fbb4c), 0x176c);
        strcpy(&game.getMemory<char>(action), "PSGRAPH_DONE");
        cpu.eax = event;
        call(0x44d420, {});
        NFS2_ASSERT(memcmp(&game.getMemory<uint8_t>(0x662ca0), &game.getMemory<uint8_t>(0x6fbb4c), 0x176c) == 0);
        game.getMemory<uint32_t>(0x6fbc10) = 0x12345678;
        strcpy(&game.getMemory<char>(action), "PSGRAPH_CANCEL");
        cpu.eax = event;
        call(0x44d420, {});
        NFS2_ASSERT(memcmp(&game.getMemory<uint8_t>(0x662ca0), &game.getMemory<uint8_t>(0x6fbb4c), 0x176c) == 0);
        NFS2_ASSERT(call(0x4350a0, {}) == 1);
        win32::WindowClass windowClass(0x4cd2d0);
        game.getMemory<uint32_t>(0x561268) = 1;
        game.getMemory<uint32_t>(0x7f7060) = 0x200;
        game.getMemory<uint32_t>(0x7f7064) = 0x4cd190;
        game.getMemory<uint32_t>(0x9f3d24) = window;
        game.getMemory<uint32_t>(0x564368) = 1;
        uint32_t criticalSection = memory.getBlockStart() + 512;
        game.getMemory<win32::Mutex*>(criticalSection) = &mutex;
        game.getMemory<uint32_t>(0x561290) = criticalSection;
        game.getMemory<uint32_t>(0x56446c) = 0;
        auto poll = [&] {
            cpu.eax = cpu.edx = cpu.ebx = cpu.ecx = 0;
            call(0x435310, {});
        };
        auto dispatch = [&](const win32::MSG& message) {
            cpu.esp = memory.getBlockStart() + memory.getBlockSize() - 256;
            uint32_t top = cpu.esp;
            win32::user32::DispatchMessageA(&game, cpu, &message);
            NFS2_ASSERT(!cpu.terminate && cpu.esp == top);
        };
        auto drainMessages = [&] {
            win32::Window::postMessage(0, 0x400, 0, 0);
            win32::MSG message{};
            for (unsigned index = 0; index < 64; ++index)
            {
                win32::Window::getMessage(cpu, &message, nullptr, 0, 0);
                if (message.message == 0x400) return;
            }
            NFS2_ASSERT(false);
        };
        drainMessages();
        for (unsigned iteration = 0; iteration < 8; ++iteration)
        {
            setRaceActive(iteration % 2 != 0);
            game.getMemory<uint32_t>(0x7a3d10) = 1;
            game.getMemory<uint32_t>(0x6fd3a0) = 0;
            game.getMemory<int32_t>(0x5f38e0) = 0; game.getMemory<int32_t>(0x5f38e4) = 0;
            game.getMemory<int32_t>(0x5f38e8) = 639; game.getMemory<int32_t>(0x5f38ec) = 479;
            game.getMemory<int32_t>(0x5f38f0) = 12; game.getMemory<int32_t>(0x5f38f4) = 34;
            pointer(0.5, 0.25, 1); pointer(0.5, 0.25, 0);
            updateGameState(&game);
            win32::MSG message{};
            for (unsigned expected : {0x201, 0x202})
                NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == expected);
            uint32_t before[3][4]{}, after[3][4]{};
            NFS2_ASSERT(readMouse(&game, before, 16, 3, true) == 3);
            strcpy(&game.getMemory<char>(action), "PSGRAPH_DONE");
            cpu.eax = event;
            call(0x44d420, {});
            drainMessages();
            game.getMemory<int32_t>(0x9f4f4c) = 64; game.getMemory<int32_t>(0x9f4f50) = 48;
            game.getMemory<int32_t>(0x9f4f44) = 576; game.getMemory<int32_t>(0x9f4f40) = 432;
            game.getMemory<int32_t>(0x9f4f3c) = 320; game.getMemory<int32_t>(0x9f4f38) = 120;
            bool lowerBoundary = iteration % 4 >= 2;
            int restoredX = lowerBoundary ? 64 : 576, restoredY = lowerBoundary ? 48 : 432;
            uint32_t restoredPosition = uint32_t(restoredX) | uint32_t(restoredY) << 16;
            message = {};
            message.hWindow = window; message.message = 0x200;
            message.lParam = lowerBoundary ? 0 : (600 | 460 << 16);
            dispatch(message);
            NFS2_ASSERT(game.getMemory<int32_t>(0x9f4f3c) == restoredX && game.getMemory<int32_t>(0x9f4f38) == restoredY);
            NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 12 && game.getMemory<int32_t>(0x5f38f4) == 34);
            NFS2_ASSERT(readMouse(&game, after, 16, 3, true) == 3 && memcmp(before, after, sizeof(before)) == 0);
            NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == 0x200);
            NFS2_ASSERT(message.wParam == 1 && message.lParam == restoredPosition);
            dispatch(message);
            win32::Window::postMessage(0, 0x400, 0, 0);
            NFS2_ASSERT(win32::Window::getMessage(cpu, &message, nullptr, 0, 0) == 1 && message.message == 0x400);
            uint8_t mouseState[16]{};
            readMouseState(mouseState, sizeof(mouseState));
            int32_t movement[2]{};
            memcpy(movement, mouseState, sizeof(movement));
            NFS2_ASSERT(movement[0] == 308 && movement[1] == 86 && mouseState[12] == 0x80);
            poll();
            NFS2_ASSERT(game.getMemory<int32_t>(0x5f38f0) == 320 && game.getMemory<int32_t>(0x5f38f4) == 120);
            NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 1);
            updateGameState(&game); poll();
            NFS2_ASSERT((game.getMemory<uint32_t>(0x5f38f8) & 0x101) == 0x100);
        }
        setRaceActive(false);
        win32::platform::log("NFS3_CURSOR_DIAGNOSTIC: PASS eight Done/window-message transitions in menu and paused-race state; original DispatchMessageA/4cd2d0/4cd190/4cc890/SetCursorPos path, both cursor boundaries, bounded warp message, intact DirectInput motion and press/release");
        call(0xa84100, {});
        win32::platform::log("NFS3_GRAPHICS_DIAGNOSTIC: PASS original Voodoo init, repeated close/open/pageflip, unchanged pause-graphics Done/Cancel callbacks and shutdown");
    }
}
void graphicsAllocationDiagnostic()
{
    @autoreleasepool
    {
        nfs3hp::Application game("nfs3.exe");
        struct RenderHookState { bool active = false; unsigned completed = 0; } hookState;
        setRenderDiagnosticHook([](void* context, bool active) {
            auto state = static_cast<RenderHookState*>(context);
            NFS2_ASSERT(state->active != active);
            state->active = active;
            if (!active) ++state->completed;
        }, &hookState);
        for (auto failure : {RenderAllocation::Color, RenderAllocation::Depth, RenderAllocation::Vertices})
        {
            win32::Renderer renderer(&game, nullptr);
            win32::GlideRenderer glide(&renderer);
            glide.setColorFactor(0); glide.setAlphaFactor(0);
            auto quad = [&](float horizontal, float vertical, float width, float height, uint32_t color, float depth = 20000) {
                win32::GrVertex vertices[4]{};
                const float positions[4][2] = {{horizontal, vertical}, {horizontal + width, vertical}, {horizontal + width, vertical + height}, {horizontal, vertical + height}};
                for (unsigned index = 0; index < 4; ++index)
                {
                    auto& vertex = vertices[index];
                    vertex.x = positions[index][0]; vertex.y = positions[index][1];
                    vertex.ooz = depth; vertex.oow = 1;
                    vertex.r = (color >> 16) & 255; vertex.g = (color >> 8) & 255; vertex.b = color & 255; vertex.a = 255;
                }
                glide.drawTriangle(&vertices[0], &vertices[1], &vertices[2]);
                glide.drawTriangle(&vertices[0], &vertices[2], &vertices[3]);
            };
            if (failure == RenderAllocation::Color)
            {
                double oldWidth, oldHeight, width, height;
                presentationSize(oldWidth, oldHeight);
                failNextRenderAllocation(failure);
                glide.clear(0xff0000); glide.swap();
                presentationSize(width, height);
                NFS2_ASSERT(!hookState.active && width == oldWidth && height == oldHeight);
            }
            glide.clear(0x204080);
            quad(100, 100, 100, 100, 0x204080);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff804020);
            if (failure != RenderAllocation::Color) renderer.setVideoMode(1024, 768, 16);
            uint64_t attempts = renderAllocationCount(failure);
            failNextRenderAllocation(failure);
            glide.clear(0xff0000);
            for (unsigned index = 0; index < (failure == RenderAllocation::Vertices ? 20 : 1); ++index)
                quad(100, 100, 100, 100, 0xff0000);
            unsigned completed = hookState.completed;
            glide.swap();
            NFS2_ASSERT(!hookState.active && hookState.completed == completed + 1);
            NFS2_ASSERT(renderAllocationCount(failure) == attempts + 1);
            double width, height;
            presentationSize(width, height);
            NFS2_ASSERT(width == 640 && height == 480);
            if (failure == RenderAllocation::Color) NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff804020);
            quad(100, 100, 100, 100, 0x00ff00);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff00ff00);
            NFS2_ASSERT(renderer.diagnosticPixel(400, 300) == (failure == RenderAllocation::Color ? 0xff804020 : 0xff000000));
            quad(100, 100, 100, 100, 0xff0000, 40000);
            glide.swap();
            NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == 0xff00ff00);
            for (auto size : {std::array<unsigned, 2>{1024, 768}, {800, 600}, {640, 480}})
            {
                renderer.setVideoMode(size[0], size[1], 16);
                for (unsigned warmup = 0; warmup < 2; ++warmup)
                {
                    glide.clear(0x204080);
                    quad(100, 100, 100, 100, 0x00ff00);
                    glide.swap();
                }
                std::array<uint64_t, 3> counts{renderAllocationCount(RenderAllocation::Color), renderAllocationCount(RenderAllocation::Depth), renderAllocationCount(RenderAllocation::Vertices)};
                for (unsigned frame = 0; frame < 60; ++frame)
                {
                    glide.clear(0x204080);
                    quad(100, 100, 100, 100, frame % 2 ? 0x00ff00 : 0xff0000);
                    glide.swap();
                    NFS2_ASSERT(renderer.diagnosticPixel(150, 150) == (frame % 2 ? 0xff00ff00 : 0xff0000ff));
                    NFS2_ASSERT(renderer.diagnosticPixel(400, 300) == 0xff804020);
                }
                NFS2_ASSERT(renderAllocationCount(RenderAllocation::Color) == counts[0]);
                NFS2_ASSERT(renderAllocationCount(RenderAllocation::Depth) == counts[1]);
                NFS2_ASSERT(renderAllocationCount(RenderAllocation::Vertices) == counts[2]);
            }
        }
        setRenderDiagnosticHook(nullptr, nullptr);
        failNextRenderAllocation(RenderAllocation::None);
        win32::platform::log("NFS3_ALLOCATION_DIAGNOSTIC: PASS injected color/depth/vertex allocation failures, first-frame and resized-frame recovery, retained last presentation, discarded failed batches, balanced render hooks, initialized persistent depth and 540 GPU-readback frames with no further color/depth/vertex allocations after warmup");
    }
}
}
