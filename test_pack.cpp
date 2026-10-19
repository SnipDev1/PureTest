#include <iostream>
#include <immintrin.h>
#include <cstdint>

alignas(16) static const uint8_t SWAP_0_1[16] = {1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_2[16] = {2, 1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

static inline __m512i pack_4_boards(__m128i b0, __m128i b1, __m128i b2, __m128i b3) {
    __m256i y0 = _mm256_set_m128i(b1, b0);
    __m256i y1 = _mm256_set_m128i(b3, b2);
    __m512i z  = _mm512_castsi256_si512(y0);
    return _mm512_inserti64x4(z, y1, 1);
}

int main() {
    static const uint8_t VALID_16[16] = {0, 2, 4, 1, 12, 8, 13, 11, 14, 5, 15, 6, 3, 10, 7, 9};
    __m128i p0 = _mm_loadu_si128((const __m128i*)VALID_16);
    __m128i m_swap_0_1 = _mm_load_si128((const __m128i*)SWAP_0_1);
    __m128i m_swap_0_2 = _mm_load_si128((const __m128i*)SWAP_0_2);

    __m128i p0_0 = p0, p0_1 = _mm_shuffle_epi8(p0_0, m_swap_0_1), p0_2 = _mm_shuffle_epi8(p0_1, m_swap_0_2);
    __m128i p0_3 = _mm_shuffle_epi8(p0_2, m_swap_0_1);

    __m512i zmm0 = pack_4_boards(p0_0, p0_1, p0_2, p0_3);

    alignas(64) uint8_t b[64];
    _mm512_store_si512((__m512i*)b, zmm0);

    std::cout << "Lane 0 in zmm0: ";
    for (int i = 0; i < 16; ++i) std::cout << (int)b[i] << " ";
    std::cout << std::endl;
    std::cout << "VALID_16      : ";
    for (int i = 0; i < 16; ++i) std::cout << (int)VALID_16[i] << " ";
    std::cout << std::endl;
    return 0;
}
