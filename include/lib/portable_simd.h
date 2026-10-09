#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>

struct alignas(16) __m128i
{
    uint8_t bytes[16];
};

template<class Lane> inline Lane simdLane(__m128i value, unsigned index)
{
    Lane result;
    memcpy(&result, value.bytes + index * sizeof(Lane), sizeof(Lane));
    return result;
}

template<class Lane> inline void simdSet(__m128i& value, unsigned index, Lane lane)
{
    memcpy(value.bytes + index * sizeof(Lane), &lane, sizeof(Lane));
}

inline __m128i _mm_cvtsi64_si128(int64_t value)
{
    __m128i result{};
    simdSet(result, 0, value);
    return result;
}
inline __m128i _mm_cvtsi32_si128(int32_t value)
{
    __m128i result{};
    simdSet(result, 0, value);
    return result;
}
inline int64_t _mm_cvtsi128_si64(__m128i value) { return simdLane<int64_t>(value, 0); }
inline int32_t _mm_cvtsi128_si32(__m128i value) { return simdLane<int32_t>(value, 0); }
inline __m128i _mm_loadu_si32(const void* address)
{
    __m128i result{};
    memcpy(result.bytes, address, 4);
    return result;
}
inline void _mm_storeu_si32(void* address, __m128i value) { memcpy(address, value.bytes, 4); }

template<class Lane, class Operation> inline __m128i simdBinary(__m128i left, __m128i right, Operation operation)
{
    __m128i result{};
    for (unsigned index = 0; index < 16 / sizeof(Lane); ++index)
        simdSet<Lane>(result, index, operation(simdLane<Lane>(left, index), simdLane<Lane>(right, index)));
    return result;
}
inline __m128i _mm_add_epi16(__m128i left, __m128i right) { return simdBinary<uint16_t>(left, right, [](auto first, auto second) { return first + second; }); }
inline __m128i _mm_add_epi32(__m128i left, __m128i right) { return simdBinary<uint32_t>(left, right, [](auto first, auto second) { return first + second; }); }
inline __m128i _mm_and_si128(__m128i left, __m128i right) { return simdBinary<uint64_t>(left, right, [](auto first, auto second) { return first & second; }); }
inline __m128i _mm_or_si128(__m128i left, __m128i right) { return simdBinary<uint64_t>(left, right, [](auto first, auto second) { return first | second; }); }
inline __m128i _mm_xor_si128(__m128i left, __m128i right) { return simdBinary<uint64_t>(left, right, [](auto first, auto second) { return first ^ second; }); }
inline __m128i _mm_adds_epi16(__m128i left, __m128i right) { return simdBinary<int16_t>(left, right, [](auto first, auto second) { return std::clamp(int(first) + int(second), -32768, 32767); }); }
inline __m128i _mm_mulhi_epi16(__m128i left, __m128i right) { return simdBinary<int16_t>(left, right, [](auto first, auto second) { return (int(first) * int(second)) >> 16; }); }
inline __m128i _mm_madd_epi16(__m128i left, __m128i right)
{
    __m128i result{};
    for (unsigned index = 0; index < 4; ++index)
    {
        int64_t first = int64_t(simdLane<int16_t>(left, index * 2)) * simdLane<int16_t>(right, index * 2);
        int64_t second = int64_t(simdLane<int16_t>(left, index * 2 + 1)) * simdLane<int16_t>(right, index * 2 + 1);
        simdSet<uint32_t>(result, index, uint32_t(first + second));
    }
    return result;
}
template<class Lane> inline __m128i simdUnpack(__m128i left, __m128i right)
{
    __m128i result{};
    for (unsigned index = 0; index < 8 / sizeof(Lane); ++index)
    {
        simdSet<Lane>(result, index * 2, simdLane<Lane>(left, index));
        simdSet<Lane>(result, index * 2 + 1, simdLane<Lane>(right, index));
    }
    return result;
}
inline __m128i _mm_unpacklo_epi8(__m128i left, __m128i right) { return simdUnpack<uint8_t>(left, right); }
inline __m128i _mm_unpacklo_epi16(__m128i left, __m128i right) { return simdUnpack<uint16_t>(left, right); }
inline __m128i _mm_unpacklo_epi32(__m128i left, __m128i right) { return simdUnpack<uint32_t>(left, right); }
template<class Source, class Destination> inline __m128i simdPack(__m128i left, __m128i right, int minimum, int maximum)
{
    __m128i result{};
    constexpr unsigned laneCount = 16 / sizeof(Source);
    for (unsigned index = 0; index < laneCount * 2; ++index)
        simdSet<Destination>(result, index, Destination(std::clamp(int(simdLane<Source>(index < laneCount ? left : right, index % laneCount)), minimum, maximum)));
    return result;
}
inline __m128i _mm_packs_epi16(__m128i left, __m128i right) { return simdPack<int16_t, int8_t>(left, right, -128, 127); }
inline __m128i _mm_packus_epi16(__m128i left, __m128i right) { return simdPack<int16_t, uint8_t>(left, right, 0, 255); }
inline __m128i _mm_packs_epi32(__m128i left, __m128i right) { return simdPack<int32_t, int16_t>(left, right, -32768, 32767); }
template<class Lane> inline __m128i simdShift(__m128i value, int count, bool left)
{
    __m128i result{};
    for (unsigned index = 0; index < 16 / sizeof(Lane); ++index)
    {
        Lane lane = simdLane<Lane>(value, index);
        simdSet<Lane>(result, index, count >= int(sizeof(Lane) * 8) ? 0 : (left ? lane << count : lane >> count));
    }
    return result;
}
inline __m128i _mm_slli_epi32(__m128i value, int count) { return simdShift<uint32_t>(value, count, true); }
inline __m128i _mm_slli_epi64(__m128i value, int count) { return simdShift<uint64_t>(value, count, true); }
inline __m128i _mm_srli_epi16(__m128i value, int count) { return simdShift<uint16_t>(value, count, false); }
inline __m128i _mm_srli_epi32(__m128i value, int count) { return simdShift<uint32_t>(value, count, false); }
inline __m128i _mm_srli_epi64(__m128i value, int count) { return simdShift<uint64_t>(value, count, false); }
inline __m128i _mm_srai_epi32(__m128i value, int count)
{
    __m128i result{};
    for (unsigned index = 0; index < 4; ++index)
        simdSet<int32_t>(result, index, simdLane<int32_t>(value, index) >> std::min(count, 31));
    return result;
}
inline __m128i _mm_srli_si128(__m128i value, int count)
{
    __m128i result{};
    if (count < 16) memcpy(result.bytes, value.bytes + count, 16 - count);
    return result;
}
