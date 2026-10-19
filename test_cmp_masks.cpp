#include <iostream>
#include <immintrin.h>
#include <cstdint>

alignas(32) static const uint8_t ROTATE_LEFT_1[32] = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0
};
alignas(32) static const uint8_t SUB_REV[32] = {
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
};
alignas(32) static const uint8_t SUB_FWD[32] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(64) static const uint8_t ROTATE_LEFT_1_512[64] = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0
};
alignas(64) static const uint8_t SUB_REV_512[64] = {
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
};
alignas(64) static const uint8_t SUB_FWD_512[64] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

int main() {
    static const uint8_t VALID_16[16] = {0, 2, 4, 1, 12, 8, 13, 11, 14, 5, 15, 6, 3, 10, 7, 9};
    __m128i v = _mm_loadu_si128((const __m128i*)VALID_16);

    // AVX2 on v (in lower half of ymm0)
    __m256i ymm = _mm256_set_m128i(v, v);
    __m256i sub_rev_256 = _mm256_load_si256((const __m256i*)SUB_REV);
    __m256i sub_fwd_256 = _mm256_load_si256((const __m256i*)SUB_FWD);
    __m256i rot_mask_256 = _mm256_load_si256((const __m256i*)ROTATE_LEFT_1);

    __m256i d1_256 = _mm256_sub_epi8(ymm, sub_rev_256);
    __m256i d2_256 = _mm256_sub_epi8(ymm, sub_fwd_256);
    __m256i r1_256 = d1_256, r2_256 = d2_256;
    uint32_t mask_256 = 0;
    for (int s = 0; s < 8; ++s) {
        r1_256 = _mm256_shuffle_epi8(r1_256, rot_mask_256);
        r2_256 = _mm256_shuffle_epi8(r2_256, rot_mask_256);
        __m256i m = _mm256_or_si256(_mm256_cmpeq_epi8(r1_256, d1_256), _mm256_cmpeq_epi8(r2_256, d2_256));
        mask_256 |= (uint32_t)_mm256_movemask_epi8(m);
    }

    // AVX-512 on v (in all 4 lanes of zmm)
    __m512i zmm = _mm512_broadcast_i64x2(v);
    __m512i sub_rev_512 = _mm512_load_si512((const __m512i*)SUB_REV_512);
    __m512i sub_fwd_512 = _mm512_load_si512((const __m512i*)SUB_FWD_512);
    __m512i rot_mask_512 = _mm512_load_si512((const __m512i*)ROTATE_LEFT_1_512);

    __m512i d1_512 = _mm512_sub_epi8(zmm, sub_rev_512);
    __m512i d2_512 = _mm512_sub_epi8(zmm, sub_fwd_512);
    __m512i r1_512 = d1_512, r2_512 = d2_512;
    uint64_t mask_512 = 0;
    for (int s = 0; s < 8; ++s) {
        r1_512 = _mm512_shuffle_epi8(r1_512, rot_mask_512);
        r2_512 = _mm512_shuffle_epi8(r2_512, rot_mask_512);
        __mmask64 m = _mm512_cmpeq_epi8_mask(r1_512, d1_512) | _mm512_cmpeq_epi8_mask(r2_512, d2_512);
        mask_512 |= (uint64_t)m;
    }

    std::cout << "AVX2 mask: 0x" << std::hex << mask_256 << std::endl;
    std::cout << "AVX-512 mask: 0x" << std::hex << mask_512 << std::endl;
    return 0;
}
