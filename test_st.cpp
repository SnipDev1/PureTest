#include <iostream>
#include <chrono>
#include <vector>
#include <thread>
#include <atomic>
#include <numeric>
#include <immintrin.h>
#include <cstdint>
#include <windows.h>

alignas(32) static const uint8_t ROTATE_LEFT_1[32] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0};
alignas(32) static const uint8_t SUB_REV[32] = {15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0};
alignas(32) static const uint8_t SUB_FWD[32] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_1[16] = {1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_2[16] = {2, 1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_3[16] = {3, 1, 2, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_1_3[16] = {0, 3, 2, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_2_3[16] = {0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
alignas(16) static const uint8_t SWAP_0_4[16] = {4, 1, 2, 3, 0, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

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

static void heap_permute_avx2(int k, uint8_t* A, uint64_t& count, uint64_t& sols, const std::atomic<bool>& stop_flag) {
    if (k == 5) { permute5_avx2(A, count, sols); return; }
    for (int i = 0; i < k; ++i) {
        if (stop_flag.load(std::memory_order_relaxed)) return;
        heap_permute_avx2(k - 1, A, count, sols, stop_flag);
        if (k % 2 == 0) std::swap(A[i], A[k - 1]); else std::swap(A[0], A[k - 1]);
    }
}

int main() {
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    uint8_t A[16]; std::iota(A, A + 16, 0);
    uint64_t pos = 0, sols = 0; std::atomic<bool> stop{false};
    auto t0 = std::chrono::high_resolution_clock::now();
    std::thread th([&]() {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
        while (!stop.load(std::memory_order_relaxed)) heap_permute_avx2(16, A, pos, sols, stop);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    stop.store(true, std::memory_order_relaxed);
    th.join();
    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    std::cout << "1 Core (Single-Thread) on Battery: " << (pos / sec / 1e6) << " MP/s" << std::endl;
    return 0;
}
