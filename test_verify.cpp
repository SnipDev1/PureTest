#include <iostream>
#include <vector>
#include <algorithm>
#include <numeric>
#include <cstdint>
#include <atomic>
#include <immintrin.h>

alignas(32) static const uint8_t ROTATE_LEFT_1[32] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0};
alignas(32) static const uint8_t SUB_REV[32] = {15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0};
alignas(32) static const uint8_t SUB_FWD[32] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_1[16] = {1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_2[16] = {2, 1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_3[16] = {3, 1, 2, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_1_3[16] = {0, 3, 2, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_2_3[16] = {0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_4[16] = {4, 1, 2, 3, 0, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

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

static inline bool check_perm_scalar(const uint8_t* Q) {
    uint32_t d1_used = 0, d2_used = 0;
    for (int i = 0; i < 16; ++i) {
        int d1 = Q[i] - i + 15, d2 = Q[i] + i;
        uint32_t b1 = 1u << d1, b2 = 1u << d2;
        if ((d1_used & b1) || (d2_used & b2)) return false;
        d1_used |= b1; d2_used |= b2;
    }
    return true;
}

static inline uint32_t check_6_perms_avx2(__m128i perm0) {
    __m128i m_swap_0_1 = _mm_load_si128((const __m128i*)SWAP_0_1);
    __m128i m_swap_0_2 = _mm_load_si128((const __m128i*)SWAP_0_2);
    __m128i perm1 = _mm_shuffle_epi8(perm0, m_swap_0_1);
    __m128i perm2 = _mm_shuffle_epi8(perm1, m_swap_0_2);
    __m128i perm3 = _mm_shuffle_epi8(perm2, m_swap_0_1);
    __m128i perm4 = _mm_shuffle_epi8(perm3, m_swap_0_2);
    __m128i perm5 = _mm_shuffle_epi8(perm4, m_swap_0_1);
    __m256i ymm0 = _mm256_set_m128i(perm5, perm0);
    __m256i ymm1 = _mm256_set_m128i(perm2, perm1);
    __m256i ymm2 = _mm256_set_m128i(perm4, perm3);
    __m256i sub_rev = _mm256_load_si256((const __m256i*)SUB_REV);
    __m256i sub_fwd = _mm256_load_si256((const __m256i*)SUB_FWD);
    __m256i rot_mask = _mm256_load_si256((const __m256i*)ROTATE_LEFT_1);
    __m256i d1_0 = _mm256_sub_epi8(ymm0, sub_rev), d1_1 = _mm256_sub_epi8(ymm1, sub_rev), d1_2 = _mm256_sub_epi8(ymm2, sub_rev);
    __m256i d2_0 = _mm256_sub_epi8(ymm0, sub_fwd), d2_1 = _mm256_sub_epi8(ymm1, sub_fwd), d2_2 = _mm256_sub_epi8(ymm2, sub_fwd);
    __m256i rot_d1_0 = d1_0, rot_d1_1 = d1_1, rot_d1_2 = d1_2;
    __m256i rot_d2_0 = d2_0, rot_d2_1 = d2_1, rot_d2_2 = d2_2;
    uint32_t mask0 = 0, mask1 = 0, mask2 = 0;
    for (int shift = 0; shift < 8; ++shift) {
        rot_d1_0 = _mm256_shuffle_epi8(rot_d1_0, rot_mask); rot_d1_1 = _mm256_shuffle_epi8(rot_d1_1, rot_mask); rot_d1_2 = _mm256_shuffle_epi8(rot_d1_2, rot_mask);
        rot_d2_0 = _mm256_shuffle_epi8(rot_d2_0, rot_mask); rot_d2_1 = _mm256_shuffle_epi8(rot_d2_1, rot_mask); rot_d2_2 = _mm256_shuffle_epi8(rot_d2_2, rot_mask);
        __m256i m0 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_0, d1_0), _mm256_cmpeq_epi8(rot_d2_0, d2_0));
        __m256i m1 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_1, d1_1), _mm256_cmpeq_epi8(rot_d2_1, d2_1));
        __m256i m2 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_2, d1_2), _mm256_cmpeq_epi8(rot_d2_2, d2_2));
        mask0 |= (uint32_t)_mm256_movemask_epi8(m0); mask1 |= (uint32_t)_mm256_movemask_epi8(m1); mask2 |= (uint32_t)_mm256_movemask_epi8(m2);
    }
    uint32_t sols = 0;
    if ((mask0 & 0x0000FFFF) == 0) sols++; if ((mask0 & 0xFFFF0000) == 0) sols++;
    if ((mask1 & 0x0000FFFF) == 0) sols++; if ((mask1 & 0xFFFF0000) == 0) sols++;
    if ((mask2 & 0x0000FFFF) == 0) sols++; if ((mask2 & 0xFFFF0000) == 0) sols++;
    return sols;
}

static inline void permute5_avx2(const uint8_t* A, uint64_t& count, uint64_t& sols) {
    __m128i m_s03 = _mm_load_si128((const __m128i*)SWAP_0_3);
    __m128i m_s13 = _mm_load_si128((const __m128i*)SWAP_1_3);
    __m128i m_s23 = _mm_load_si128((const __m128i*)SWAP_2_3);
    __m128i m_s04 = _mm_load_si128((const __m128i*)SWAP_0_4);
    __m128i p = _mm_loadu_si128((const __m128i*)A);
    for (int i4 = 0; i4 < 5; ++i4) {
        sols += check_6_perms_avx2(p); p = _mm_shuffle_epi8(p, m_s03);
        sols += check_6_perms_avx2(p); p = _mm_shuffle_epi8(p, m_s13);
        sols += check_6_perms_avx2(p); p = _mm_shuffle_epi8(p, m_s23);
        sols += check_6_perms_avx2(p); p = _mm_shuffle_epi8(p, m_s04);
    }
    count += 120;
}

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
    return sols;
}

static inline void permute5_avx512(const uint8_t* A, uint64_t& count, uint64_t& sols) {
    __m128i m_s03 = _mm_load_si128((const __m128i*)SWAP_0_3);
    __m128i m_s13 = _mm_load_si128((const __m128i*)SWAP_1_3);
    __m128i m_s23 = _mm_load_si128((const __m128i*)SWAP_2_3);
    __m128i m_s04 = _mm_load_si128((const __m128i*)SWAP_0_4);

    __m128i p = _mm_loadu_si128((const __m128i*)A);
    for (int i4 = 0; i4 < 5; ++i4) {
        __m128i p0 = p;
        __m128i p1 = _mm_shuffle_epi8(p0, m_s03);
        sols += check_12_perms_avx512(p0, p1);
        __m128i p2 = _mm_shuffle_epi8(p1, m_s13);
        __m128i p3 = _mm_shuffle_epi8(p2, m_s23);
        sols += check_12_perms_avx512(p2, p3);
        p = _mm_shuffle_epi8(p3, m_s04);
    }
    count += 120;
}

static void heap_permute_scalar(int k, uint8_t* A, uint64_t& count, uint64_t& sols) {
    if (k == 1) { if (check_perm_scalar(A)) sols++; count++; return; }
    for (int i = 0; i < k; ++i) {
        heap_permute_scalar(k - 1, A, count, sols);
        if (k % 2 == 0) std::swap(A[i], A[k - 1]); else std::swap(A[0], A[k - 1]);
    }
}

int main() {
    static const uint8_t VALID_16[16] = {0, 2, 4, 1, 12, 8, 13, 11, 14, 5, 15, 6, 3, 10, 7, 9};
    uint8_t s_scal[16], s_avx2[16], s_avx512[16];
    std::copy(VALID_16, VALID_16 + 16, s_scal);
    std::copy(VALID_16, VALID_16 + 16, s_avx2);
    std::copy(VALID_16, VALID_16 + 16, s_avx512);

    uint64_t c_scal = 0, sol_scal = 0;
    heap_permute_scalar(5, s_scal, c_scal, sol_scal);

    uint64_t c_2 = 0, sol_2 = 0;
    permute5_avx2(s_avx2, c_2, sol_2);

    uint64_t c_5 = 0, sol_5 = 0;
    permute5_avx512(s_avx512, c_5, sol_5);

    std::cout << "Scalar: " << c_scal << " pos, " << sol_scal << " sols" << std::endl;
    std::cout << "AVX2  : " << c_2    << " pos, " << sol_2    << " sols" << std::endl;
    std::cout << "AVX512: " << c_5    << " pos, " << sol_5    << " sols" << std::endl;

    return 0;
}
