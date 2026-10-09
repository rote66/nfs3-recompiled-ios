#include <metal_stdlib>
using namespace metal;

struct VertexData { float4 position; float4 color; float4 texture; };
struct RasterData
{
    float4 position [[position]];
    float4 color;
    float3 texture;
    float2 combine [[flat]];
};
vertex RasterData glideVertex(const device VertexData* vertices [[buffer(0)]],
                             constant float2& size [[buffer(1)]], uint index [[vertex_id]])
{
    VertexData value = vertices[index];
    RasterData result;
    result.position = float4(value.position.x * 2 / size.x - 1, 1 - value.position.y * 2 / size.y,
                             clamp(value.position.z / 65536.0f, 0.0f, 1.0f), 1);
    result.color = value.color;
    result.texture = value.texture.xyz;
    result.combine = float2(value.position.w, value.texture.w);
    return result;
}
fragment float4 glideFragment(RasterData input [[stage_in]], texture2d<float> image [[texture(0)]],
                              sampler filtering [[sampler(0)]], constant uint4& settings [[buffer(0)]])
{
    float reciprocal = abs(input.texture.z) < 1e-20f ? 1 : input.texture.z;
    float2 coordinates = input.texture.xy / (reciprocal * 256);
    float4 texel;
    if (settings.y)
    {
        int2 size = int2(image.get_width(), image.get_height());
        bool2 wrap = bool2(settings.x & 1, settings.x & 2);
        float2 bounded = select(clamp(coordinates, 0.0f, 1.0f), fract(coordinates), wrap);
        float2 position = bounded * float2(size) - 0.5f;
        int2 base = int2(floor(position));
        float2 fraction = fract(position);
        const int2 offsets[] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
        float weights[] = {(1 - fraction.x) * (1 - fraction.y), fraction.x * (1 - fraction.y),
                           (1 - fraction.x) * fraction.y, fraction.x * fraction.y};
        uint3 key = uint3((settings.z >> 16) & 255, (settings.z >> 8) & 255, settings.z & 255);
        float total = 0;
        texel = 0;
        for (uint index = 0; index < 4; ++index)
        {
            int2 location = base + offsets[index];
            location = select(clamp(location, int2(0), size - 1), (location + size) % size, wrap);
            float4 sample = image.read(uint2(location));
            if (all(uint3(round(sample.rgb * 255)) == key)) continue;
            texel += sample * weights[index];
            total += weights[index];
        }
        if (total <= 0) discard_fragment();
        texel /= total;
    }
    else texel = image.sample(filtering, coordinates);
    float4 color = float4(mix(input.color.rgb, input.color.rgb * texel.rgb, input.combine.x),
                          mix(input.color.a, input.color.a * texel.a, input.combine.y));
    if (color.a <= settings.w / 255.0f) discard_fragment();
    return color;
}
struct ClearData { float4 position [[position]]; };
vertex ClearData clearVertex(uint index [[vertex_id]])
{
    const float2 corners[] = {float2(-1, 1), float2(3, 1), float2(-1, -3)};
    ClearData result;
    result.position = float4(corners[index], 1, 1);
    return result;
}
fragment float4 clearFragment(constant float4& color [[buffer(0)]])
{
    return color;
}
struct ScreenData { float4 position [[position]]; float2 coordinates; };
vertex ScreenData screenVertex(uint index [[vertex_id]])
{
    const float2 corners[] = {float2(-1, 1), float2(3, 1), float2(-1, -3)};
    ScreenData result;
    result.position = float4(corners[index], 0, 1);
    result.coordinates = float2((corners[index].x + 1) / 2, (1 - corners[index].y) / 2);
    return result;
}
fragment float4 screenFragment(ScreenData input [[stage_in]], texture2d<float> image [[texture(0)]])
{
    constexpr sampler filtering(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(filtering, input.coordinates).rgb, 1);
}
