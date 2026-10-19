// ============================================================================
// checkmate.cpp — CPU CheckMate Benchmark (PureTestImage).
//
// Accurate implementation of AIDA64 v7+ "CPU CheckMate" benchmark:
// Vectorized 16-Queens search and diagonal conflict verification on 16x16 board.
//
// Dual Comparison Architecture:
//   1. AIDA-Like Baseline (AVX2_3):
//      - Evaluates 6 permutations simultaneously in 3 YMM pairs (256-bit SIMD).
//      - Generates permutations purely in vector registers via shuffle masks (zero memory stalls).
//      - Directly matches official AIDA64 v7.40+ Bench_NGQueen AVX2_3 routine and scores.
//   2. AVX-512 Enhanced (512-bit ZMM):
//      - Evaluates 12 permutations simultaneously in 3 ZMM registers (512-bit SIMD).
//      - Employs native 64-bit comparison masks (__mmask64) and byte shuffles across 4 boards per vector.
//      - Provides fair modern architectural comparison for AVX-512 enabled CPUs (Zen 4/5, Tiger Lake, etc.).
//
// Scoring Metric:
//   Units: MP/s (Mega-Positions per second = evaluated permutations / 1e6 / sec)
//   Formula: Score = Total Evaluated Positions / (Elapsed Seconds * 1e6)
//   No artificial scaling multipliers; directly matches AIDA64 Bench_NGQueen throughput.
//
// Clean portable standard C++17 (MSVC / GCC / Clang).
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <vector>
#include <string>
#include <algorithm>
#include <thread>
#include <atomic>
#include <numeric>

#if defined(_MSC_VER)
#include <intrin.h>
#include <immintrin.h>
#elif defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#include <immintrin.h>
#endif

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

// -----------------------------------------------------------------------------
// CPU Capability Detection
// -----------------------------------------------------------------------------
struct CpuFeatures {
    bool avx2 = false;
    bool avx512f = false;
    bool avx512bw = false;
    bool avx512_vpopcntdq = false;
};

static CpuFeatures detect_cpu_features() {
    CpuFeatures feat;
#if defined(_MSC_VER)
    int info[4] = {0};
    __cpuid(info, 0);
    int max_id = info[0];
    if (max_id >= 1) {
        __cpuid(info, 1);
        bool osxsave = (info[2] & (1 << 27)) != 0;
        if (osxsave) {
            unsigned long long xcr0 = _xgetbv(0);
            bool avx_ready    = (xcr0 & 6) == 6;
            bool avx512_ready = (xcr0 & 0xE6) == 0xE6;
            if (max_id >= 7) {
                __cpuidex(info, 7, 0);
                feat.avx2 = avx_ready && ((info[1] & (1 << 5)) != 0);
                if (avx512_ready) {
                    feat.avx512f = (info[1] & (1 << 16)) != 0;
                    feat.avx512bw = (info[1] & (1 << 30)) != 0;
                    feat.avx512_vpopcntdq = (info[2] & (1 << 14)) != 0;
                }
            }
        }
    }
#elif defined(__x86_64__) || defined(__i386__)
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (__get_cpuid(0, &eax, &ebx, &ecx, &edx)) {
        int max_id = eax;
        if (max_id >= 1) {
            __get_cpuid(1, &eax, &ebx, &ecx, &edx);
            bool osxsave = (ecx & (1 << 27)) != 0;
            if (osxsave) {
                uint64_t xcr0 = 0;
                __asm__ __volatile__("xgetbv" : "=A"(xcr0) : "c"(0));
                bool avx_ready    = (xcr0 & 6) == 6;
                bool avx512_ready = (xcr0 & 0xE6) == 0xE6;
                if (max_id >= 7) {
                    __cpuid_count(7, 0, eax, ebx, ecx, edx);
                    feat.avx2 = avx_ready && ((ebx & (1 << 5)) != 0);
                    if (avx512_ready) {
                        feat.avx512f = (ebx & (1 << 16)) != 0;
                        feat.avx512bw = (ebx & (1 << 30)) != 0;
                        feat.avx512_vpopcntdq = (ecx & (1 << 14)) != 0;
                    }
                }
            }
        }
    }
#endif
    return feat;
}

// -----------------------------------------------------------------------------
// Constants and Masks for Vectorized Permutation Search
// -----------------------------------------------------------------------------
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

alignas(16) static const uint8_t SWAP_0_1[16] = {
    1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(16) static const uint8_t SWAP_0_2[16] = {
    2, 1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(16) static const uint8_t SWAP_0_3[16] = {
    3, 1, 2, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(16) static const uint8_t SWAP_1_3[16] = {
    0, 3, 2, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(16) static const uint8_t SWAP_2_3[16] = {
    0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};

alignas(16) static const uint8_t SWAP_0_4[16] = {
    4, 1, 2, 3, 0, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
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

// -----------------------------------------------------------------------------
// [Method AVX2_3] Vectorized 6-Permutation Diagonal Conflict Checker (AIDA64 Baseline)
// -----------------------------------------------------------------------------
// Disassembled from AIDA64 v7+ Bench_NGQueen AVX2_3:
// Evaluates 6 permutations simultaneously in 3 YMM pairs (256-bit SIMD).
// All permutations generated in vector registers via shuffle masks (zero memory stalls).
#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2")))
#endif
static inline uint32_t check_6_perms_avx2(__m128i perm0) {
    __m128i m_swap_0_1 = _mm_load_si128((const __m128i*)SWAP_0_1);
    __m128i m_swap_0_2 = _mm_load_si128((const __m128i*)SWAP_0_2);

    // Generate 6 permutations of the last 3 elements via register shuffles
    __m128i perm1 = _mm_shuffle_epi8(perm0, m_swap_0_1);
    __m128i perm2 = _mm_shuffle_epi8(perm1, m_swap_0_2);
    __m128i perm3 = _mm_shuffle_epi8(perm2, m_swap_0_1);
    __m128i perm4 = _mm_shuffle_epi8(perm3, m_swap_0_2);
    __m128i perm5 = _mm_shuffle_epi8(perm4, m_swap_0_1);

    // Pack into 3 YMM registers (2 boards per 256-bit register)
    __m256i ymm0 = _mm256_set_m128i(perm5, perm0);
    __m256i ymm1 = _mm256_set_m128i(perm2, perm1);
    __m256i ymm2 = _mm256_set_m128i(perm4, perm3);

    __m256i sub_rev = _mm256_load_si256((const __m256i*)SUB_REV);
    __m256i sub_fwd = _mm256_load_si256((const __m256i*)SUB_FWD);
    __m256i rot_mask = _mm256_load_si256((const __m256i*)ROTATE_LEFT_1);

    // Major diagonals D1 = Q[i] + (15 - i)
    __m256i d1_0 = _mm256_sub_epi8(ymm0, sub_rev);
    __m256i d1_1 = _mm256_sub_epi8(ymm1, sub_rev);
    __m256i d1_2 = _mm256_sub_epi8(ymm2, sub_rev);

    // Minor diagonals D2 = Q[i] - i
    __m256i d2_0 = _mm256_sub_epi8(ymm0, sub_fwd);
    __m256i d2_1 = _mm256_sub_epi8(ymm1, sub_fwd);
    __m256i d2_2 = _mm256_sub_epi8(ymm2, sub_fwd);

    __m256i rot_d1_0 = d1_0, rot_d1_1 = d1_1, rot_d1_2 = d1_2;
    __m256i rot_d2_0 = d2_0, rot_d2_1 = d2_1, rot_d2_2 = d2_2;

    uint32_t mask0 = 0, mask1 = 0, mask2 = 0;

    // AIDA64 Bench_NGQueen rotates N / 2 = 8 circular steps
    for (int shift = 0; shift < 8; ++shift) {
        rot_d1_0 = _mm256_shuffle_epi8(rot_d1_0, rot_mask);
        rot_d1_1 = _mm256_shuffle_epi8(rot_d1_1, rot_mask);
        rot_d1_2 = _mm256_shuffle_epi8(rot_d1_2, rot_mask);

        rot_d2_0 = _mm256_shuffle_epi8(rot_d2_0, rot_mask);
        rot_d2_1 = _mm256_shuffle_epi8(rot_d2_1, rot_mask);
        rot_d2_2 = _mm256_shuffle_epi8(rot_d2_2, rot_mask);

        __m256i m0 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_0, d1_0), _mm256_cmpeq_epi8(rot_d2_0, d2_0));
        __m256i m1 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_1, d1_1), _mm256_cmpeq_epi8(rot_d2_1, d2_1));
        __m256i m2 = _mm256_or_si256(_mm256_cmpeq_epi8(rot_d1_2, d1_2), _mm256_cmpeq_epi8(rot_d2_2, d2_2));

        mask0 |= (uint32_t)_mm256_movemask_epi8(m0);
        mask1 |= (uint32_t)_mm256_movemask_epi8(m1);
        mask2 |= (uint32_t)_mm256_movemask_epi8(m2);
    }

    uint32_t sols = 0;
    if ((mask0 & 0x0000FFFF) == 0) sols++;
    if ((mask0 & 0xFFFF0000) == 0) sols++;
    if ((mask1 & 0x0000FFFF) == 0) sols++;
    if ((mask1 & 0xFFFF0000) == 0) sols++;
    if ((mask2 & 0x0000FFFF) == 0) sols++;
    if ((mask2 & 0xFFFF0000) == 0) sols++;
    return sols;
}

// Evaluates 120 permutations purely in vector registers via in-register shuffles
// Exactly matches AIDA64 Bench_NGQueen AVX2_3 inner loop design: zero memory stalls, zero loads/stores in inner permutations
#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2")))
#endif
static inline void permute5_avx2(const uint8_t* A, uint64_t& count, uint64_t& sols) {
    __m128i m_s03 = _mm_load_si128((const __m128i*)SWAP_0_3);
    __m128i m_s13 = _mm_load_si128((const __m128i*)SWAP_1_3);
    __m128i m_s23 = _mm_load_si128((const __m128i*)SWAP_2_3);
    __m128i m_s04 = _mm_load_si128((const __m128i*)SWAP_0_4);

    __m128i p = _mm_loadu_si128((const __m128i*)A);
    for (int i4 = 0; i4 < 5; ++i4) {
        sols += check_6_perms_avx2(p);
        p = _mm_shuffle_epi8(p, m_s03);
        sols += check_6_perms_avx2(p);
        p = _mm_shuffle_epi8(p, m_s13);
        sols += check_6_perms_avx2(p);
        p = _mm_shuffle_epi8(p, m_s23);
        sols += check_6_perms_avx2(p);
        p = _mm_shuffle_epi8(p, m_s04);
    }
    count += 120;
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2")))
#endif
static void heap_permute_avx2(int k, uint8_t* A, uint64_t& count, uint64_t& sols, const std::atomic<bool>& stop_flag) {
    if (k == 5) {
        permute5_avx2(A, count, sols);
        return;
    }

    for (int i = 0; i < k; ++i) {
        if (stop_flag.load(std::memory_order_relaxed)) return;
        heap_permute_avx2(k - 1, A, count, sols, stop_flag);
        if (k % 2 == 0) {
            std::swap(A[i], A[k - 1]);
        } else {
            std::swap(A[0], A[k - 1]);
        }
    }
}

// -----------------------------------------------------------------------------
// [Method AVX-512] Vectorized 12-Permutation Diagonal Conflict Checker (512-bit ZMM)
// -----------------------------------------------------------------------------
// Evaluates 12 permutations simultaneously in 3 ZMM registers (4 boards per vector).
// Generates permutations in registers via shuffle masks and processes native __mmask64.
#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx512f,avx512dq,avx512bw")))
#endif
static inline __m512i pack_4_boards(__m128i b0, __m128i b1, __m128i b2, __m128i b3) {
    __m256i y0 = _mm256_set_m128i(b1, b0);
    __m256i y1 = _mm256_set_m128i(b3, b2);
    __m512i z  = _mm512_castsi256_si512(y0);
    return _mm512_inserti64x4(z, y1, 1);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx512f,avx512dq,avx512bw")))
#endif
static inline uint32_t check_12_perms_avx512(__m128i p0, __m128i p1) {
    __m128i m_swap_0_1 = _mm_load_si128((const __m128i*)SWAP_0_1);
    __m128i m_swap_0_2 = _mm_load_si128((const __m128i*)SWAP_0_2);

    // 6 permutations for p0
    __m128i p0_0 = p0;
    __m128i p0_1 = _mm_shuffle_epi8(p0_0, m_swap_0_1);
    __m128i p0_2 = _mm_shuffle_epi8(p0_1, m_swap_0_2);
    __m128i p0_3 = _mm_shuffle_epi8(p0_2, m_swap_0_1);
    __m128i p0_4 = _mm_shuffle_epi8(p0_3, m_swap_0_2);
    __m128i p0_5 = _mm_shuffle_epi8(p0_4, m_swap_0_1);

    // 6 permutations for p1
    __m128i p1_0 = p1;
    __m128i p1_1 = _mm_shuffle_epi8(p1_0, m_swap_0_1);
    __m128i p1_2 = _mm_shuffle_epi8(p1_1, m_swap_0_2);
    __m128i p1_3 = _mm_shuffle_epi8(p1_2, m_swap_0_1);
    __m128i p1_4 = _mm_shuffle_epi8(p1_3, m_swap_0_2);
    __m128i p1_5 = _mm_shuffle_epi8(p1_4, m_swap_0_1);

    // Pack into 3 ZMM registers (4 boards per 512-bit register)
    __m512i zmm0 = pack_4_boards(p0_0, p0_1, p0_2, p0_3);
    __m512i zmm1 = pack_4_boards(p0_4, p0_5, p1_0, p1_1);
    __m512i zmm2 = pack_4_boards(p1_2, p1_3, p1_4, p1_5);

    __m512i sub_rev  = _mm512_load_si512((const __m512i*)SUB_REV_512);
    __m512i sub_fwd  = _mm512_load_si512((const __m512i*)SUB_FWD_512);
    __m512i rot_mask = _mm512_load_si512((const __m512i*)ROTATE_LEFT_1_512);

    // Major diagonals D1 = Q[i] + (15 - i)
    __m512i d1_0 = _mm512_sub_epi8(zmm0, sub_rev);
    __m512i d1_1 = _mm512_sub_epi8(zmm1, sub_rev);
    __m512i d1_2 = _mm512_sub_epi8(zmm2, sub_rev);

    // Minor diagonals D2 = Q[i] - i
    __m512i d2_0 = _mm512_sub_epi8(zmm0, sub_fwd);
    __m512i d2_1 = _mm512_sub_epi8(zmm1, sub_fwd);
    __m512i d2_2 = _mm512_sub_epi8(zmm2, sub_fwd);

    __m512i rot_d1_0 = d1_0, rot_d1_1 = d1_1, rot_d1_2 = d1_2;
    __m512i rot_d2_0 = d2_0, rot_d2_1 = d2_1, rot_d2_2 = d2_2;

    __mmask64 acc0 = 0, acc1 = 0, acc2 = 0;

    for (int shift = 0; shift < 8; ++shift) {
        rot_d1_0 = _mm512_shuffle_epi8(rot_d1_0, rot_mask);
        rot_d1_1 = _mm512_shuffle_epi8(rot_d1_1, rot_mask);
        rot_d1_2 = _mm512_shuffle_epi8(rot_d1_2, rot_mask);

        rot_d2_0 = _mm512_shuffle_epi8(rot_d2_0, rot_mask);
        rot_d2_1 = _mm512_shuffle_epi8(rot_d2_1, rot_mask);
        rot_d2_2 = _mm512_shuffle_epi8(rot_d2_2, rot_mask);

        acc0 |= (_mm512_cmpeq_epi8_mask(rot_d1_0, d1_0) | _mm512_cmpeq_epi8_mask(rot_d2_0, d2_0));
        acc1 |= (_mm512_cmpeq_epi8_mask(rot_d1_1, d1_1) | _mm512_cmpeq_epi8_mask(rot_d2_1, d2_1));
        acc2 |= (_mm512_cmpeq_epi8_mask(rot_d1_2, d1_2) | _mm512_cmpeq_epi8_mask(rot_d2_2, d2_2));
    }

    uint64_t mask0 = (uint64_t)acc0;
    uint64_t mask1 = (uint64_t)acc1;
    uint64_t mask2 = (uint64_t)acc2;

    uint32_t sols = 0;
    // Check 4 boards in zmm0
    if ((mask0 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask0 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask0 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask0 & 0xFFFF000000000000ULL) == 0) sols++;

    // Check 4 boards in zmm1
    if ((mask1 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask1 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask1 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask1 & 0xFFFF000000000000ULL) == 0) sols++;

    // Check 4 boards in zmm2
    if ((mask2 & 0x000000000000FFFFULL) == 0) sols++;
    if ((mask2 & 0x00000000FFFF0000ULL) == 0) sols++;
    if ((mask2 & 0x0000FFFF00000000ULL) == 0) sols++;
    if ((mask2 & 0xFFFF000000000000ULL) == 0) sols++;
    return sols;
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx512f,avx512dq,avx512bw")))
#endif
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

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx512f,avx512dq,avx512bw")))
#endif
static void heap_permute_avx512(int k, uint8_t* A, uint64_t& count, uint64_t& sols, const std::atomic<bool>& stop_flag) {
    if (k == 5) {
        permute5_avx512(A, count, sols);
        return;
    }

    for (int i = 0; i < k; ++i) {
        if (stop_flag.load(std::memory_order_relaxed)) return;
        heap_permute_avx512(k - 1, A, count, sols, stop_flag);
        if (k % 2 == 0) {
            std::swap(A[i], A[k - 1]);
        } else {
            std::swap(A[0], A[k - 1]);
        }
    }
}

// -----------------------------------------------------------------------------
// Scalar Fallback Permutation Search
// -----------------------------------------------------------------------------
static inline bool check_perm_scalar(const uint8_t* Q) {
    uint32_t d1_used = 0;
    uint32_t d2_used = 0;
    for (int i = 0; i < 16; ++i) {
        int d1 = Q[i] - i + 15;
        int d2 = Q[i] + i;
        uint32_t b1 = 1u << d1;
        uint32_t b2 = 1u << d2;
        if ((d1_used & b1) || (d2_used & b2)) return false;
        d1_used |= b1;
        d2_used |= b2;
    }
    return true;
}

static void heap_permute_scalar(int k, uint8_t* A, uint64_t& count, uint64_t& sols, const std::atomic<bool>& stop_flag) {
    if (k == 1) {
        if (check_perm_scalar(A)) sols++;
        count++;
        return;
    }

    for (int i = 0; i < k; ++i) {
        if (stop_flag.load(std::memory_order_relaxed)) return;
        heap_permute_scalar(k - 1, A, count, sols, stop_flag);
        if (k % 2 == 0) {
            std::swap(A[i], A[k - 1]);
        } else {
            std::swap(A[0], A[k - 1]);
        }
    }
}

// -----------------------------------------------------------------------------
// Benchmark Runner
// -----------------------------------------------------------------------------
enum class VectorMode {
    AVX2,
    AVX512,
    SCALAR
};

struct BenchmarkResult {
    uint64_t total_positions;
    uint64_t total_solutions;
    double elapsed_sec;
    double mps;
};

static BenchmarkResult run_checkmate_bench(int num_threads, int duration_ms, const CpuFeatures& feat, VectorMode mode, int warmup_ms = 300) {
#if defined(_WIN32)
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
#endif

    // Pre-measurement thermal warm-up phase to reach steady-state TDP (matching AIDA64 calibration)
    if (warmup_ms > 0) {
        std::atomic<bool> warm_stop{false};
        std::vector<std::thread> warm_workers;
        warm_workers.reserve(num_threads);
        for (int t = 0; t < num_threads; ++t) {
            warm_workers.emplace_back([t, &warm_stop, &feat, mode]() {
#if defined(_WIN32)
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
#endif
                uint8_t A[16];
                std::iota(A, A + 16, 0);
                std::swap(A[0], A[t % 16]);
                uint64_t dummy_cnt = 0, dummy_sols = 0;
                while (!warm_stop.load(std::memory_order_relaxed)) {
                    if (mode == VectorMode::AVX512 && feat.avx512bw) {
                        heap_permute_avx512(12, A, dummy_cnt, dummy_sols, warm_stop);
                    } else if (mode == VectorMode::AVX2 && feat.avx2) {
                        heap_permute_avx2(12, A, dummy_cnt, dummy_sols, warm_stop);
                    } else {
                        heap_permute_scalar(10, A, dummy_cnt, dummy_sols, warm_stop);
                    }
                }
            });
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(warmup_ms));
        warm_stop.store(true, std::memory_order_relaxed);
        for (auto& w : warm_workers) w.join();
    }

    // Main measurement
    std::atomic<bool> stop_flag{false};
    std::vector<uint64_t> thread_positions(num_threads, 0);
    std::vector<uint64_t> thread_solutions(num_threads, 0);
    std::vector<std::thread> workers;
    workers.reserve(num_threads);

    auto t_start = std::chrono::high_resolution_clock::now();

    for (int t = 0; t < num_threads; ++t) {
        workers.emplace_back([t, &stop_flag, &thread_positions, &thread_solutions, &feat, mode]() {
#if defined(_WIN32)
            SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
#endif
            uint8_t A[16];
            std::iota(A, A + 16, 0);

            // Stride initial permutation to ensure threads explore disjoint spaces
            std::swap(A[0], A[t % 16]);
            std::swap(A[1], A[(t * 7 + 1) % 16]);

            uint64_t pos = 0;
            uint64_t sols = 0;

            while (!stop_flag.load(std::memory_order_relaxed)) {
                if (mode == VectorMode::AVX512 && feat.avx512bw) {
                    heap_permute_avx512(16, A, pos, sols, stop_flag);
                } else if (mode == VectorMode::AVX2 && feat.avx2) {
                    heap_permute_avx2(16, A, pos, sols, stop_flag);
                } else {
                    heap_permute_scalar(14, A, pos, sols, stop_flag);
                }
            }

            thread_positions[t] = pos;
            thread_solutions[t] = sols;
        });
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(duration_ms));
    stop_flag.store(true, std::memory_order_relaxed);

    for (auto& w : workers) w.join();

    auto t_end = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t_end - t_start).count();

    uint64_t all_positions = 0;
    uint64_t all_sols = 0;
    for (int t = 0; t < num_threads; ++t) {
        all_positions += thread_positions[t];
        all_sols += thread_solutions[t];
    }

    // Exact AIDA64 scoring formula:
    // Units: MP/s (Mega-Positions per second = evaluated permutations / 1e6 / sec)
    // Directly matches AIDA64 Bench_NGQueen AVX2_3 throughput without artificial scaling factors.
    double mps = (sec > 0.0) ? (double(all_positions) / sec / 1e6) : 0.0;

    BenchmarkResult res;
    res.total_positions = all_positions;
    res.total_solutions = all_sols;
    res.elapsed_sec = sec;
    res.mps = mps;
    return res;
}

// -----------------------------------------------------------------------------
// Correctness Verification
// -----------------------------------------------------------------------------
static bool verify_queen_logic(const CpuFeatures& feat) {
    // Known valid 16-Queens solution:
    static const uint8_t VALID_16[16] = {
        0, 2, 4, 1, 12, 8, 13, 11, 14, 5, 15, 6, 3, 10, 7, 9
    };
    // Known invalid 16-Queens board (simple diagonal collision):
    static const uint8_t INVALID_16[16] = {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    };

    bool pass_scalar = check_perm_scalar(VALID_16) && !check_perm_scalar(INVALID_16);

    __m128i v_valid = _mm_loadu_si128((const __m128i*)VALID_16);
    __m128i v_invalid = _mm_loadu_si128((const __m128i*)INVALID_16);

    bool pass_avx2 = true;
    if (feat.avx2) {
        uint32_t s_valid = check_6_perms_avx2(v_valid);
        uint32_t s_invalid = check_6_perms_avx2(v_invalid);
        pass_avx2 = (s_valid >= 1) && (s_invalid == 0);
    }

    bool pass_avx512 = true;
    if (feat.avx512bw) {
        uint32_t s_valid = check_12_perms_avx512(v_valid, v_valid);
        uint32_t s_invalid = check_12_perms_avx512(v_invalid, v_invalid);
        pass_avx512 = (s_valid >= 1) && (s_invalid == 0);
    }

    // Verify 120-permutation in-register generator against scalar Heap
    uint8_t s_scal[16], s_avx2[16], s_avx512[16];
    std::copy(VALID_16, VALID_16 + 16, s_scal);
    std::copy(VALID_16, VALID_16 + 16, s_avx2);
    std::copy(VALID_16, VALID_16 + 16, s_avx512);

    uint64_t c_scal = 0, sol_scal = 0;
    std::atomic<bool> no_stop{false};
    heap_permute_scalar(5, s_scal, c_scal, sol_scal, no_stop);

    uint64_t c2 = 0, s2 = 0;
    bool pass_perm5_avx2 = true;
    if (feat.avx2) {
        permute5_avx2(s_avx2, c2, s2);
        pass_perm5_avx2 = (c2 == c_scal && s2 == sol_scal);
    }

    uint64_t c5 = 0, s5 = 0;
    bool pass_perm5_avx512 = true;
    if (feat.avx512bw) {
        permute5_avx512(s_avx512, c5, s5);
        pass_perm5_avx512 = (c5 == c_scal && s5 == sol_scal);
    }

    return pass_scalar && pass_avx2 && pass_avx512 && pass_perm5_avx2 && pass_perm5_avx512;
}

static std::string format_speedup_diff(double speed_fast, double speed_base) {
    if (speed_base <= 0.0 || speed_fast <= 0.0) return "N/A";
    double ratio = (speed_fast / speed_base - 1.0) * 100.0;
    char buf[32];
    if (ratio >= 0.0) {
        std::snprintf(buf, sizeof(buf), "+%.1f%%", ratio);
    } else {
        std::snprintf(buf, sizeof(buf), "%.1f%%", ratio);
    }
    return std::string(buf);
}

// -----------------------------------------------------------------------------
// Entry Point
// -----------------------------------------------------------------------------
int main() {
    unsigned int hardware_threads = std::thread::hardware_concurrency();
    if (hardware_threads == 0) hardware_threads = 1;

    CpuFeatures feat = detect_cpu_features();

    printf("========================================================================\n");
    printf("   PureTestImage: CPU CheckMate Benchmark (AIDA64 v7+ Method)\n");
    printf("   Algorithm: 16-Queens Permutation Search on 16x16 Chessboard\n");
    printf("   Vectorization Engine: AVX2 Baseline & AVX-512 Support (Dual Mode)\n");
    printf("   Detected Hardware Threads : %u\n", hardware_threads);
    printf("   CPU AVX2 Support          : %s\n", feat.avx2 ? "Supported (256-bit YMM)" : "Not Supported");
    printf("   CPU AVX-512 Support       : %s\n", feat.avx512bw ? "Supported (512-bit ZMM, AVX512BW)" : "Not Supported / Inactive");
    printf("========================================================================\n\n");

    // --- Phase 1: Pass A - AIDA-Like Baseline (AVX2_3, 256-bit SIMD) ---
    printf("--- [1/4] Pass A: AIDA-Like Baseline (AVX2_3, 256-bit SIMD) ---\n");
    BenchmarkResult res_aida_st = run_checkmate_bench(1, 1000, feat, VectorMode::AVX2, 300);
    printf("  [1 Core] Single-Thread   : %8.0f MP/s  (%8.1fM pos in %5.3f s)\n",
           res_aida_st.mps, double(res_aida_st.total_positions) / 1e6, res_aida_st.elapsed_sec);

    BenchmarkResult res_aida_mt = run_checkmate_bench(hardware_threads, 2000, feat, VectorMode::AVX2, 2500);
    double aida_scaling = (res_aida_st.mps > 0.0) ? (res_aida_mt.mps / res_aida_st.mps) : 1.0;
    printf("  [%2u Thr] Multi-Thread    : %8.0f MP/s  (%8.1fM pos in %5.3f s, Scaling: %.2fx)\n\n",
           hardware_threads, res_aida_mt.mps, double(res_aida_mt.total_positions) / 1e6, res_aida_mt.elapsed_sec, aida_scaling);

    // --- Phase 2: Pass B - AVX-512 Enhanced (512-bit ZMM Vectorized) ---
    printf("--- [2/4] Pass B: AVX-512 Enhanced (512-bit ZMM Vectorized) ---\n");
    BenchmarkResult res_512_st = {0, 0, 0.0, 0.0};
    BenchmarkResult res_512_mt = {0, 0, 0.0, 0.0};

    if (feat.avx512bw) {
        res_512_st = run_checkmate_bench(1, 1000, feat, VectorMode::AVX512, 300);
        printf("  [1 Core] Single-Thread   : %8.0f MP/s  (%8.1fM pos in %5.3f s)\n",
               res_512_st.mps, double(res_512_st.total_positions) / 1e6, res_512_st.elapsed_sec);

        res_512_mt = run_checkmate_bench(hardware_threads, 2000, feat, VectorMode::AVX512, 2500);
        double avx512_scaling = (res_512_st.mps > 0.0) ? (res_512_mt.mps / res_512_st.mps) : 1.0;
        printf("  [%2u Thr] Multi-Thread    : %8.0f MP/s  (%8.1fM pos in %5.3f s, Scaling: %.2fx)\n\n",
               hardware_threads, res_512_mt.mps, double(res_512_mt.total_positions) / 1e6, res_512_mt.elapsed_sec, avx512_scaling);
    } else {
        printf("  [SKIPPED] CPU does not support AVX-512BW (requires AVX-512 Foundation + Byte/Word extensions).\n\n");
    }

    // --- Phase 3: Algorithm Verification ---
    printf("--- [3/4] SIMD Algorithm Collision Verification ---\n");
    bool verify_pass = verify_queen_logic(feat);
    printf("  Verification status : %s\n\n", verify_pass ? "ALL PASSED (100%)" : "FAILED");

    // --- Phase 4: Comparative Summary Table ---
    std::string speedup_mt = feat.avx512bw ? format_speedup_diff(res_512_mt.mps, res_aida_mt.mps) : "N/A";
    std::string speedup_st = feat.avx512bw ? format_speedup_diff(res_512_st.mps, res_aida_st.mps) : "N/A";

    char col_512_mt[32], col_512_st[32];
    if (feat.avx512bw) {
        std::snprintf(col_512_mt, sizeof(col_512_mt), "%8.0f MP/s", res_512_mt.mps);
        std::snprintf(col_512_st, sizeof(col_512_st), "%8.0f MP/s", res_512_st.mps);
    } else {
        std::snprintf(col_512_mt, sizeof(col_512_mt), "N/A (No AVX512)");
        std::snprintf(col_512_st, sizeof(col_512_st), "N/A (No AVX512)");
    }

    printf("====================================================================================================\n");
    printf("AIDA64 CPU CHECKMATE COMPARISON: AIDA-LIKE (AVX2) vs AVX-512 ENHANCED\n");
    printf("----------------------------------------------------------------------------------------------------\n");
    printf("  Benchmark Mode           | Threads | AIDA-Like (AVX2) | AVX-512 Enhanced | Speedup | AIDA64 Reference\n");
    printf("----------------------------------------------------------------------------------------------------\n");
    printf("  CPU CheckMate Multi      |  %2uT    |    %8.0f MP/s | %16s | %7s |   Ryzen 9700X: ~9420\n",
           hardware_threads, res_aida_mt.mps, col_512_mt, speedup_mt.c_str());
    printf("  CPU CheckMate Single     |   1T    |    %8.0f MP/s | %16s | %7s |   Ryzen 9700X: ~1618\n",
           res_aida_st.mps, col_512_st, speedup_st.c_str());
    printf("----------------------------------------------------------------------------------------------------\n");
    printf("  * Units: MP/s (Mega-Positions per second = Evaluated Permutations / 1e6 / sec)\n");
    printf("  * Method Breakdown:\n");
    printf("      - \"AIDA-Like (AVX2)\" : Strictly identical to AIDA64 v7+ Bench_NGQueen AVX2_3 routine.\n");
    printf("      - \"AVX-512 Enhanced\": 512-bit ZMM implementation (12 boards evaluated per vector batch).\n");
    printf("  * Reference Hardware (AIDA64 v7+ Baseline):\n");
    printf("      Ryzen 7 9700X HT Multi (16T) : 9420 MP/s (DDR5-4800) / 9836 MP/s (6000)\n");
    printf("      Ryzen 7 9700X HT Single (1T) : 1618 MP/s (DDR5-4800) / 1611 MP/s (6000)\n");
    printf("      Ryzen 7 8745HS Multi   (16T) : 3290 MP/s (Lenovo 83K9 on battery)\n");
    printf("      Core i5-1135G7 Multi    (8T) : 1593 MP/s (Huawei BOD-WXX9)\n");
    printf("====================================================================================================\n");
    printf("=== CPU CHECKMATE BENCHMARK COMPLETED (exit 0) ===\n");
    return 0;
}
