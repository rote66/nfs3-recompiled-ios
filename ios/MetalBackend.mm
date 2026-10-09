#import <MetalKit/MetalKit.h>
#include "Native.h"
#include <lib/renderer.h>
#include <lib/gliderenderer.h>
#include <nfs3hp.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <map>
#include <mutex>
#include <thread>

namespace
{
id<MTLDevice> device;
id<MTLCommandQueue> queue;
id<MTLLibrary> library;
id<MTLRenderPipelineState> screenPipeline;
id<MTLRenderPipelineState> glidePipelines[2];
id<MTLRenderPipelineState> clearPipeline;
id<MTLDepthStencilState> depthStates[4];
id<MTLSamplerState> textureSamplers[4];
MTKView* displayView;
std::mutex displayMutex;
std::mutex frameMutex;
id<MTLTexture> displayedTexture;
std::atomic<double> fps{0};
std::atomic<double> gpuTime{0};
uint64_t lastFrame = 0;
std::atomic<void (*)(void*, bool)> renderDiagnosticHook{nullptr};
void* renderDiagnosticContext = nullptr;
std::atomic<nfsios::RenderAllocation> failedAllocation{nfsios::RenderAllocation::None};
std::array<std::atomic<uint64_t>, 4> allocationCounts{};

bool allocateRenderResource(nfsios::RenderAllocation allocation)
{
    ++allocationCounts[unsigned(allocation)];
    auto expected = allocation;
    if (!failedAllocation.compare_exchange_strong(expected, nfsios::RenderAllocation::None)) return true;
    win32::platform::log("NFS3_METAL_ALLOCATION: injected failure type=%u", unsigned(allocation));
    return false;
}

id<MTLTexture> texture(unsigned width, unsigned height, MTLPixelFormat format, MTLTextureUsage usage)
{
    if (!width || !height)
    {
        win32::platform::log("NFS3_METAL_ALLOCATION: rejected invalid texture %ux%u format=%u", width, height, unsigned(format));
        return nil;
    }
    auto description = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    description.usage = usage;
    description.storageMode = format == MTLPixelFormatDepth32Float ? MTLStorageModePrivate : MTLStorageModeShared;
    auto image = [device newTextureWithDescriptor:description];
    if (!image) win32::platform::log("NFS3_METAL_ALLOCATION: texture unavailable %ux%u format=%u", width, height, unsigned(format));
    return image;
}
void initializeMetal()
{
    if (device) return;
    device = MTLCreateSystemDefaultDevice();
    queue = [device newCommandQueue];
    NSError* error = nil;
    NSURL* url = [[NSBundle mainBundle] URLForResource:@"default" withExtension:@"metallib"];
    library = [device newLibraryWithURL:url error:&error];
    if (!library) { NSLog(@"Metal library: %@", error); abort(); }
    auto descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"screenVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"screenFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    screenPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    for (unsigned index = 0; index < 2; ++index)
    {
        descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"glideVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"glideFragment"];
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        auto color = descriptor.colorAttachments[0];
        color.pixelFormat = MTLPixelFormatRGBA8Unorm;
        color.blendingEnabled = YES;
        color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        color.destinationRGBBlendFactor = index ? MTLBlendFactorOne : MTLBlendFactorOneMinusSourceAlpha;
        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        glidePipelines[index] = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    }
    for (unsigned index = 0; index < 4; ++index)
    {
        auto description = [MTLDepthStencilDescriptor new];
        description.depthCompareFunction = index & 1 ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways;
        description.depthWriteEnabled = !!(index & 2);
        depthStates[index] = [device newDepthStencilStateWithDescriptor:description];
        auto sampler = [MTLSamplerDescriptor new];
        sampler.minFilter = MTLSamplerMinMagFilterLinear;
        sampler.magFilter = MTLSamplerMinMagFilterLinear;
        sampler.sAddressMode = index & 1 ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = index & 2 ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        textureSamplers[index] = [device newSamplerStateWithDescriptor:sampler];
    }
    descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"clearVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"clearFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    clearPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!screenPipeline || !glidePipelines[0] || !glidePipelines[1] || !clearPipeline) { NSLog(@"Metal pipeline: %@", error); abort(); }
}

struct Surface { id<MTLTexture> image; };
struct NativeVertex { float position[4]; float color[4]; float texture[4]; };
struct Batch
{
    std::vector<NativeVertex> vertices;
    id<MTLTexture> image;
    unsigned depth;
    unsigned blend;
    std::array<uint32_t, 4> clip;
    bool clear;
    uint32_t clearColor;
    std::array<uint32_t, 4> sampling;
};
struct GlideState
{
    std::map<uint32_t, id<MTLTexture>> images;
    id<MTLTexture> selected;
    uint32_t selectedAddress = 0;
    bool textureBound = false;
    id<MTLTexture> depth;
    bool depthInitialized = false;
    std::array<id<MTLTexture>, 2> targets{};
    unsigned targetIndex = 0;
    id<MTLBuffer> vertices;
    std::vector<Batch> batches;
    bool test = true;
    bool write = true;
    unsigned blend = 0;
    float color = 1;
    float alpha = 1;
    std::array<uint32_t, 4> clip{0, 0, UINT32_MAX, UINT32_MAX};
    unsigned clipTrace = 0;
    std::array<uint32_t, 4> sampling{3, 0, 0, 16};
};
}

@interface NFSPresentation : NSObject <MTKViewDelegate>
@end
@implementation NFSPresentation
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { (void)view; (void)size; }
- (void)drawInMTKView:(MTKView*)view
{
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    @autoreleasepool
    {
        id<MTLTexture> image;
        { std::lock_guard<std::mutex> guard(displayMutex); image = displayedTexture; }
        if (!image) return;
        auto pass = view.currentRenderPassDescriptor;
        auto drawable = view.currentDrawable;
        if (!pass || !drawable) return;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        auto command = [queue commandBuffer];
        auto encoder = [command renderCommandEncoderWithDescriptor:pass];
        double scale = std::min(view.drawableSize.width / image.width, view.drawableSize.height / image.height);
        double width = image.width * scale;
        double height = image.height * scale;
        [encoder setViewport:MTLViewport{(view.drawableSize.width - width) / 2, (view.drawableSize.height - height) / 2, width, height, 0, 1}];
        [encoder setRenderPipelineState:screenPipeline];
        [encoder setFragmentTexture:image atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [command presentDrawable:drawable];
        [command commit];
    }
}
@end

namespace nfsios
{
void attachMetal(void* view)
{
    initializeMetal();
    displayView = (__bridge MTKView*)view;
    displayView.device = device;
    displayView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    displayView.paused = YES;
    displayView.enableSetNeedsDisplay = YES;
    static NFSPresentation* presentation = [NFSPresentation new];
    displayView.delegate = presentation;
}
void* metalDevice() { initializeMetal(); return (__bridge void*)device; }
void setRenderDiagnosticHook(void (*hook)(void*, bool), void* context)
{
    renderDiagnosticContext = context;
    renderDiagnosticHook.store(hook, std::memory_order_release);
}
void failNextRenderAllocation(RenderAllocation allocation) { failedAllocation = allocation; }
uint64_t renderAllocationCount(RenderAllocation allocation) { return allocationCounts[unsigned(allocation)]; }
void presentTexture(void* value)
{
    id<MTLTexture> frame = (__bridge id<MTLTexture>)value;
    waitActive();
    std::lock_guard<std::mutex> frameGuard(frameMutex);
    auto now = win32::platform::nanoseconds();
    if (lastFrame && now - lastFrame < 16666667)
        std::this_thread::sleep_for(std::chrono::nanoseconds(16666667 - (now - lastFrame)));
    now = win32::platform::nanoseconds();
    if (lastFrame) fps = fps.load() * 0.85 + (1e9 / double(now - lastFrame)) * 0.15;
    lastFrame = now;
    { std::lock_guard<std::mutex> guard(displayMutex); if (frame) displayedTexture = frame; }
    dispatch_async(dispatch_get_main_queue(), ^{ [displayView setNeedsDisplay]; });
}
double framesPerSecond() { return fps; }
double gpuMilliseconds() { return gpuTime; }
void presentationSize(double& width, double& height)
{
    std::lock_guard<std::mutex> guard(displayMutex);
    width = displayedTexture ? displayedTexture.width : 640;
    height = displayedTexture ? displayedTexture.height : 480;
}
void graphicsDiagnostic()
{
    @autoreleasepool
    {
        nfs3hp::Application app("nfs3.exe");
        win32::Renderer renderer(&app, nullptr);
        renderer.setVideoMode(640, 480, 16);
        auto memory = renderer.lock(0);
        for (unsigned index = 0; index < 640 * 480; ++index) app.getMemory<uint16_t>(memory + index * 2) = 0xf800;
        renderer.unlock(0);
        NFS2_ASSERT(renderer.diagnosticPixel(320, 240) == 0xff0000ff);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        renderer.setVideoMode(640, 480, 8);
        uint32_t colors[] = {0x000000ff, 0x00ff00ff};
        renderer.updatePalette(2, colors);
        memset(&app.getMemory<uint8_t>(renderer.lock(0)), 1, 640 * 480);
        renderer.unlock(0);
        NFS2_ASSERT(renderer.diagnosticPixel(320, 240) == 0xff00ff00);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        renderer.setVideoMode(640, 480, 16);
        win32::GlideRenderer glide(&renderer);
        glide.clear(0x102040);
        glide.setColorFactor(0);
        glide.setAlphaFactor(0);
        win32::GrVertex triangle[3]{};
        float positions[][2] = {{64, 64}, {576, 64}, {320, 416}};
        for (unsigned index = 0; index < 3; ++index)
        {
            triangle[index].x = positions[index][0]; triangle[index].y = positions[index][1];
            triangle[index].r = 255; triangle[index].a = 255;
            triangle[index].ooz = 1000; triangle[index].oow = 1;
        }
        glide.drawTriangle(&triangle[0], &triangle[1], &triangle[2]);
        for (auto& vertex : triangle) { vertex.r = 0; vertex.g = 255; vertex.ooz = 60000; }
        glide.drawTriangle(&triangle[0], &triangle[1], &triangle[2]);
        uint16_t yellow = 0xffe0;
        glide.setTextureData(0, 8, &yellow, 8, 8, win32::TF_RGB_565);
        glide.setTexture(0, 8);
        glide.setColorFactor(1);
        glide.setAlphaFactor(1);
        float texturedPositions[][2] = {{80, 80}, {180, 80}, {80, 180}};
        for (unsigned index = 0; index < 3; ++index)
        {
            triangle[index].x = texturedPositions[index][0]; triangle[index].y = texturedPositions[index][1];
            triangle[index].r = 255; triangle[index].g = 255; triangle[index].b = 255; triangle[index].ooz = 500;
        }
        glide.drawTriangle(&triangle[0], &triangle[1], &triangle[2]);
        glide.swap();
        NFS2_ASSERT(!nfsios::inRace());
        NFS2_ASSERT(renderer.diagnosticPixel(320, 240) == 0xff0000ff);
        NFS2_ASSERT(renderer.diagnosticPixel(90, 90) == 0xff00ffff);
        NFS2_ASSERT(renderer.diagnosticPixel(10, 10) == 0xff402010);
        std::this_thread::sleep_for(std::chrono::seconds(3));
        win32::platform::log("NATIVE_DIAGNOSTIC: PASS RGB565, palette, textured Metal triangles, depth and GPU readback");
    }
}
}

namespace win32
{
Renderer::Renderer(WinApplication* app, Window* window)
    : m_application(app), m_window(window), m_renderer(new Surface), m_texture(0),
      m_videoMemory(new MemMap(1024 * 768 * 4)), m_currentBuffer(0), m_width(640), m_height(480), m_depth(16), m_colorPalette{}
{
    initializeMetal();
}
Renderer::~Renderer() { delete static_cast<Surface*>(m_renderer); delete m_videoMemory; }
void Renderer::setCurrent() {}
void Renderer::clearCurrent() {}
void Renderer::present()
{
    nfsios::updateGameState(m_application);
    nfsios::presentTexture((__bridge void*)static_cast<Surface*>(m_renderer)->image);
}
x86::reg32 Renderer::diagnosticPixel(unsigned horizontal, unsigned vertical) const
{
    uint32_t pixel = 0;
    [static_cast<Surface*>(m_renderer)->image getBytes:&pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(horizontal, vertical, 1, 1) mipmapLevel:0];
    return pixel;
}
void Renderer::setVideoMode(x86::reg32 width, x86::reg32 height, x86::reg32 depth)
{
    NFS2_ASSERT(width && height && width <= 1024 && height <= 768 && (depth == 8 || depth == 16));
    if (width != m_width || height != m_height) static_cast<Surface*>(m_renderer)->image = nil;
    platform::log("NFS3_VIDEO_MODE: %ux%u depth=%u", width, height, depth);
    m_width = width; m_height = height; m_depth = depth; m_currentBuffer = 0;
}
void Renderer::updatePalette(x86::reg32 count, const x86::reg32* colors)
{
    NFS2_ASSERT(count <= 256);
    memcpy(m_colorPalette, colors, count * 4);
}
x86::reg32 Renderer::getFrontBuffer() const { return m_videoMemory->getBlockStart() + m_currentBuffer * m_width * m_height * (m_depth / 8); }
x86::reg32 Renderer::getBackBuffer() const { return m_videoMemory->getBlockStart() + (1 - m_currentBuffer) * m_width * m_height * (m_depth / 8); }
x86::reg32 Renderer::lock(x86::reg32 index) { return index == 0 ? getFrontBuffer() : getBackBuffer(); }
void Renderer::unlock(x86::reg32 index) { if (index == 0) update(); }
void Renderer::swap() { m_currentBuffer = 1 - m_currentBuffer; update(); }
void Renderer::update()
{
    @autoreleasepool
    {
        std::vector<uint8_t> pixels(size_t(m_width) * m_height * 4);
        for (unsigned index = 0; index < m_width * m_height; ++index)
        {
            uint8_t* pixel = pixels.data() + index * 4;
            if (m_depth == 8)
            {
                uint32_t color = m_colorPalette[m_application->getMemory<uint8_t>(getFrontBuffer() + index)];
                pixel[0] = color >> 24; pixel[1] = color >> 16; pixel[2] = color >> 8;
            }
            else
            {
                uint16_t color = m_application->getMemory<uint16_t>(getFrontBuffer() + index * 2);
                pixel[0] = ((color >> 11) & 31) * 255 / 31;
                pixel[1] = ((color >> 5) & 63) * 255 / 63;
                pixel[2] = (color & 31) * 255 / 31;
            }
            pixel[3] = 255;
        }
        auto image = texture(m_width, m_height, MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead);
        if (!image) { present(); return; }
        [image replaceRegion:MTLRegionMake2D(0, 0, m_width, m_height) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:m_width * 4];
        static_cast<Surface*>(m_renderer)->image = image;
        present();
    }
}
GlideRenderer::GlideRenderer(Renderer* renderer) : m_renderer(renderer), m_native(new GlideState)
{
    auto state = static_cast<GlideState*>(m_native);
    uint32_t white = 0xffffffff;
    state->selected = texture(1, 1, MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead);
    [state->selected replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
}
GlideRenderer::~GlideRenderer() { delete static_cast<GlideState*>(m_native); }
void GlideRenderer::clear(x86::reg32 color)
{
    auto state = static_cast<GlideState*>(m_native);
    state->batches.push_back(Batch{{}, nil, 2, 0, state->clip, true, color, {}});
}
void GlideRenderer::render(x86::reg32 buffer) { m_renderer->m_currentBuffer = buffer; }
void GlideRenderer::setClipWindow(x86::reg32 minX, x86::reg32 minY, x86::reg32 maxX, x86::reg32 maxY)
{
    auto state = static_cast<GlideState*>(m_native);
    std::array<uint32_t, 4> clip{minX, minY, maxX, maxY};
    if (state->clip != clip && state->clipTrace++ < 16)
        platform::log("NFS3_GLIDE_CLIP: %u,%u..%u,%u", minX, minY, maxX, maxY);
    state->clip = clip;
}
x86::reg32 GlideRenderer::textureMemStart(x86::reg32) { return 8; }
x86::reg32 GlideRenderer::textureMemEnd(x86::reg32) { return 4 * 1024 * 1024; }
x86::reg32 GlideRenderer::getTextureMemSize(x86::reg32, x86::reg32, TextureFormat) { return 8; }
void GlideRenderer::setZWrite(bool enable) { static_cast<GlideState*>(m_native)->write = enable; }
void GlideRenderer::setZTest(bool enable) { static_cast<GlideState*>(m_native)->test = enable; }
void GlideRenderer::setAlphaBlendDst(AlphaBlend blend) { static_cast<GlideState*>(m_native)->blend = blend == AB_1 ? 1 : 0; }
void GlideRenderer::setColorFactor(float factor) { static_cast<GlideState*>(m_native)->color = factor; }
void GlideRenderer::setAlphaFactor(float factor) { static_cast<GlideState*>(m_native)->alpha = factor; }
void GlideRenderer::setTextureClamp(bool wrapS, bool wrapT)
{
    static_cast<GlideState*>(m_native)->sampling[0] = unsigned(wrapS) | unsigned(wrapT) << 1;
}
void GlideRenderer::setChromakey(bool enabled) { static_cast<GlideState*>(m_native)->sampling[1] = enabled; }
void GlideRenderer::setChromakeyColor(x86::reg32 color) { static_cast<GlideState*>(m_native)->sampling[2] = color; }
void GlideRenderer::setAlphaReference(x86::reg32 value) { static_cast<GlideState*>(m_native)->sampling[3] = value & 255; }
void GlideRenderer::setTexture(x86::reg32 tmu, x86::reg32 address)
{
    NFS2_ASSERT(tmu == 0);
    auto state = static_cast<GlideState*>(m_native);
    auto found = state->images.find(address);
    NFS2_ASSERT(found != state->images.end());
    state->selectedAddress = address; state->textureBound = true; state->selected = found->second;
}
void GlideRenderer::setTextureData(x86::reg32 tmu, x86::reg32 address, const void* data, x86::reg32 large, x86::reg32 small, TextureFormat format)
{
    @autoreleasepool
    {
        NFS2_ASSERT(tmu == 0 && large <= small && small <= 8);
        NFS2_ASSERT(format == TF_RGB_565 || format == TF_ARGB_1555 || format == TF_ARGB_4444);
        unsigned size = 256 >> large;
        std::vector<uint8_t> pixels(size * size * 4);
        for (unsigned index = 0; index < size * size; ++index)
        {
            uint16_t color;
            memcpy(&color, static_cast<const uint8_t*>(data) + index * 2, 2);
            uint8_t* output = pixels.data() + index * 4;
            if (format == TF_RGB_565)
            {
                output[0] = ((color >> 11) & 31) * 255 / 31;
                output[1] = ((color >> 5) & 63) * 255 / 63;
                output[2] = (color & 31) * 255 / 31; output[3] = 255;
            }
            else if (format == TF_ARGB_1555)
            {
                output[0] = ((color >> 10) & 31) * 255 / 31;
                output[1] = ((color >> 5) & 31) * 255 / 31;
                output[2] = (color & 31) * 255 / 31; output[3] = color & 0x8000 ? 255 : 0;
            }
            else
            {
                output[0] = ((color >> 8) & 15) * 17; output[1] = ((color >> 4) & 15) * 17;
                output[2] = (color & 15) * 17; output[3] = ((color >> 12) & 15) * 17;
            }
        }
        auto image = texture(size, size, MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead);
        if (!image) return;
        [image replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:size * 4];
        auto state = static_cast<GlideState*>(m_native);
        state->images[address] = image;
        if (state->textureBound && state->selectedAddress == address) state->selected = image;
    }
}
void GlideRenderer::drawTriangle(const GrVertex* first, const GrVertex* second, const GrVertex* third)
{
    auto state = static_cast<GlideState*>(m_native);
    unsigned depth = unsigned(state->test) | (unsigned(state->write) << 1);
    if (state->batches.empty() || state->batches.back().clear || state->batches.back().image != state->selected || state->batches.back().depth != depth || state->batches.back().blend != state->blend || state->batches.back().clip != state->clip || state->batches.back().sampling != state->sampling)
        state->batches.push_back(Batch{{}, state->selected, depth, state->blend, state->clip, false, 0, state->sampling});
    for (const GrVertex* value : {first, second, third})
        state->batches.back().vertices.push_back(NativeVertex{{value->x, value->y, value->ooz, state->color},
            {value->r / 255, value->g / 255, value->b / 255, value->a / 255},
            {value->tmuvtx[0].sow, value->tmuvtx[0].tow, value->oow, state->alpha}});
}
void GlideRenderer::swap(x86::CPU* cpu)
{
    @autoreleasepool
    {
        if (auto hook = renderDiagnosticHook.load(std::memory_order_acquire)) hook(renderDiagnosticContext, true);
        auto state = static_cast<GlideState*>(m_native);
        auto surface = static_cast<Surface*>(m_renderer->m_renderer);
        auto app = m_renderer->m_application;
        auto finishFrame = [&](id<MTLTexture> image) {
            state->batches.clear();
            nfsios::updateGameState(app);
            if (auto hook = renderDiagnosticHook.load(std::memory_order_acquire)) hook(renderDiagnosticContext, false);
            if (cpu) app->unlockContext(*cpu);
            nfsios::presentTexture((__bridge void*)image);
            if (cpu) app->lockContext(*cpu);
        };
        unsigned width = m_renderer->m_width, height = m_renderer->m_height;
        auto image = state->targets[state->targetIndex];
        if (!image || image.width != width || image.height != height)
        {
            image = allocateRenderResource(nfsios::RenderAllocation::Color)
                ? texture(width, height, MTLPixelFormatRGBA8Unorm, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget) : nil;
            if (!image) { finishFrame(surface->image); return; }
            state->targets[state->targetIndex] = image;
        }
        bool replaceDepth = !state->depth || state->depth.width != width || state->depth.height != height;
        bool newDepth = replaceDepth || !state->depthInitialized;
        if (replaceDepth)
        {
            auto depth = allocateRenderResource(nfsios::RenderAllocation::Depth)
                ? texture(width, height, MTLPixelFormatDepth32Float, MTLTextureUsageRenderTarget) : nil;
            if (!depth) { finishFrame(surface->image); return; }
            state->depth = depth;
            state->depthInitialized = false;
        }
        size_t vertexBytes = 0;
        for (const auto& batch : state->batches) vertexBytes += batch.vertices.size() * sizeof(NativeVertex);
        if (vertexBytes > state->vertices.length)
        {
            size_t capacity = std::max(size_t(4096), size_t(state->vertices.length));
            while (capacity < vertexBytes) capacity *= 2;
            auto vertices = allocateRenderResource(nfsios::RenderAllocation::Vertices)
                ? [device newBufferWithLength:capacity options:MTLResourceStorageModeShared] : nil;
            if (!vertices)
            {
                platform::log("NFS3_METAL_ALLOCATION: vertex buffer unavailable bytes=%zu", capacity);
                finishFrame(surface->image); return;
            }
            state->vertices = vertices;
        }
        size_t vertexOffset = 0;
        for (const auto& batch : state->batches)
        {
            size_t bytes = batch.vertices.size() * sizeof(NativeVertex);
            if (bytes) memcpy(static_cast<uint8_t*>(state->vertices.contents) + vertexOffset, batch.vertices.data(), bytes);
            vertexOffset += bytes;
        }
        auto command = [queue commandBuffer];
        if (!command) { finishFrame(surface->image); return; }
        bool previousImage = surface->image && surface->image.width == image.width && surface->image.height == image.height;
        if (previousImage)
        {
            auto blit = [command blitCommandEncoder];
            [blit copyFromTexture:surface->image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(image.width, image.height, 1) toTexture:image destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        }
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = image;
        pass.colorAttachments[0].loadAction = previousImage ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.depthAttachment.texture = state->depth;
        pass.depthAttachment.loadAction = newDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1;
        auto encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) { finishFrame(surface->image); return; }
        float size[] = {float(m_renderer->m_width), float(m_renderer->m_height)};
        [encoder setVertexBytes:size length:sizeof(size) atIndex:1];
        vertexOffset = 0;
        for (const auto& batch : state->batches)
        {
            size_t offset = vertexOffset;
            vertexOffset += batch.vertices.size() * sizeof(NativeVertex);
            unsigned minX = std::min(unsigned(image.width), batch.clip[0]);
            unsigned minY = std::min(unsigned(image.height), batch.clip[1]);
            unsigned maxX = std::min(unsigned(image.width), batch.clip[2]);
            unsigned maxY = std::min(unsigned(image.height), batch.clip[3]);
            if (minX >= maxX || minY >= maxY) continue;
            [encoder setScissorRect:MTLScissorRect{minX, minY, maxX - minX, maxY - minY}];
            if (batch.clear)
            {
                float color[] = {((batch.clearColor >> 16) & 255) / 255.f, ((batch.clearColor >> 8) & 255) / 255.f, (batch.clearColor & 255) / 255.f, 1};
                [encoder setRenderPipelineState:clearPipeline];
                [encoder setDepthStencilState:depthStates[2]];
                [encoder setFragmentBytes:color length:sizeof(color) atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                continue;
            }
            [encoder setRenderPipelineState:glidePipelines[batch.blend]];
            [encoder setDepthStencilState:depthStates[batch.depth]];
            [encoder setVertexBuffer:state->vertices offset:offset atIndex:0];
            [encoder setFragmentTexture:batch.image atIndex:0];
            [encoder setFragmentSamplerState:textureSamplers[batch.sampling[0]] atIndex:0];
            [encoder setFragmentBytes:batch.sampling.data() length:sizeof(batch.sampling) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:batch.vertices.size()];
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError)
        {
            NSLog(@"Metal frame failed: %@", command.error);
            state->depth = nil;
            state->depthInitialized = false;
            finishFrame(surface->image); return;
        }
        gpuTime = (command.GPUEndTime - command.GPUStartTime) * 1000;
        state->depthInitialized = true;
        surface->image = image;
        state->targetIndex = 1 - state->targetIndex;
        finishFrame(image);
    }
}
}
