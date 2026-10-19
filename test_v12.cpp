#include <iostream>
#include <iomanip>
#include <immintrin.h>
#include <cstdint>

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
alignas(16) static const uint8_t SWAP_0_1[16] = {1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_2[16] = {2, 1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

static inline __m512i pack_4_boards(__m128i b0, __m128i b1, __m128i b2, __m128i b3) {
    __m256i y0 = _mm256_set_m128i(b1, b0);
    __m256i y1 = _mm256_set_m128i(b3, b2);
    __m512i z  = _mm512_castsi256_si512(y0);
    return _mm512_inserti64x4(z, y1, 1);
}

static inline uint32_t check_12_perms_avx512(__m128i p0, __m128i p1) {
    __m128i m_swap_0_1 = _mm_load_si128((const __m128i*)SWAP_0_1);
    __m128i m_swap_0_2 = _mm_load_si128((const __m128i*)SWAP_0_2);

    __m128i p0_0 = p0, p0_1 = _mm_shuffle_epi8(p0_0, m_swap_0_1), p0_2 = _mm_shuffle_epi8(p0_1, m_swap_0_2);
    __m128i p0_3 = _mm_shuffle_epi8(p0_2, m_swap_0_1), p0_4 = _mm_shuffle_epi8(p0_3, m_swap_0_2), p0_5 = _mm_shuffle_epi8(p0_4, m_swap_0_1);

    __m128i p1_0 = p1, p1_1 = _mm_shuffle_epi8(p1_0, m_swap_0_1), p1_2 = _mm_shuffle_epi8(p1_1, m_swap_0_2);
    __m128i p1_3 = _mm_shuffle_epi8(p1_2, m_swap_0_1), p1_4 = _mm_shuffle_epi8(p1_3, m_swap_0_2), p1_5 = _mm_shuffle_epi8(p1_4, m_swap_0_1);

    __m512i zmm0 = pack_4_boards(p0_0, p0_1, p0_2, p0_3);
    __m512i zmm1 = pack_4_boards(p0_4, p0_5, p1_0, p1_1);
    __m512i zmm2 = pack_4_boards(p1_2, p1_3, p1_4, p1_5);

    __m512i sub_rev  = _mm512_load_si512((const __m512i*)SUB_REV_512);
    __m512i sub_fwd  = _mm512_load_si512((const __m512i*)SUB_FWD_512);
    __m512i rot_mask = _mm512_load_si512((const __m512i*)ROTATE_LEFT_1_512);

    __m512i d1_0 = _mm512_sub_epi8(zmm0, sub_rev), d1_1 = _mm512_sub_epi8(zmm1, sub_rev), d1_2 = _mm512_sub_epi8(zmm2, sub_rev);
    __m512i d2_0 = _mm512_sub_epi8(zmm0, sub_fwd), d2_1 = _mm512_sub_epi8(zmm1, sub_fwd), d2_2 = _mm512_sub_epi8(zmm2, sub_fwd);
    __m512i rot_d1_0 = d1_0, rot_d1_1 = d1_1, rot_d1_2 = d1_2;
    __m512i rot_d2_0 = d2_0, rot_d2_1 = d2_1, rot_d2_2 = d2_2;

    uint64_t mask0 = 0, mask1 = 0, mask2 = 0;
    for (int shift = 0; shift < 8; ++shift) {
        rot_d1_0 = _mm512_shuffle_epi8(rot_d1_0, rot_mask); rot_d1_1 = _mm512_shuffle_epi8(rot_d1_1, rot_mask); rot_d1_2 = _mm512_shuffle_epi8(rot_d1_2, rot_mask);
        rot_d2_0 = _mm512_shuffle_epi8(rot_d2_0, rot_mask); rot_d2_1 = _mm512_shuffle_epi8(rot_d2_1, rot_mask); rot_d2_2 = _mm512_shuffle_epi8(rot_d2_2, rot_mask);
        __mmask64 m0 = _mm512_cmpeq_epi8_mask(rot_d1_0, d1_0) | _mm512_cmpeq_epi8_mask(rot_d2_0, d2_0);
        __mmask64 m1 = _mm512_cmpeq_epi8_mask(rot_d1_1, d1_1) | _mm512_cmpeq_epi8_mask(rot_d2_1, d2_1);
        __mmask64 m2 = _mm512_cmpeq_epi8_mask(rot_d1_2, d1_2) | _mm512_cmpeq_epi8_mask(rot_d2_2, d2_2);
        mask0 |= (uint64_t)m0; mask1 |= (uint64_t)m1; mask2 |= (uint64_t)m2;
    }

    uint32_t sols = 0;
    if ((mask0 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask0 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask0 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask0 & 0xFFFF000000000000ULL) == 0) sols++;

    if ((mask1 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask1 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask1 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask1 & 0xFFFF000000000000ULL) == 0) sols++;

    if ((mask2 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask2 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask2 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask2 & 0xFFFF000000000000ULL) == 0) sols++;

    std::cout << "sols breakdown: mask0=" << std::hex << mask0 << " mask1=" << mask1 << " mask2=" << mask2 << std::dec << " count=" << sols << std::endl;
    return sols;
}

int main() {
    static const uint8_t VALID_16[16] = {0, 2, 4, 1, 12, 8, 13, 11, 14, 5, 15, 6, 3, 10, 7, 9};
    __m128i v = _mm_loadu_si128((const __m128i*)VALID_16);
    uint32_t s = check_12_perms_avx512(v, v);
    std::cout << "Result: " << s << std::endl;
    return 0;
}
