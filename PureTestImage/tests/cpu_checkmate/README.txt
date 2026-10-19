============================================================
PureTestImage: CPU CheckMate Benchmark (AIDA64 v7+ Method)
============================================================

DESCRIPTION:
  Measures CPU integer and branch / permutation throughput by solving
  the 16-Queens puzzle on a 16x16 chessboard using vectorized diagonal
  conflict detection and register-based permutation generation.
  Outputs dual metrics: AIDA-Like (AVX2) and AVX-512 Enhanced
  for side-by-side architectural comparison.

DUAL VECTORIZATION MODES:
  1. AIDA-Like Baseline (AVX2_3, 256-bit SIMD):
     - Evaluates 6 permutations simultaneously in 3 YMM pairs (256-bit SIMD).
     - Directly matches official AIDA64 v7+ Bench_NGQueen AVX2_3 routine and scores.
  2. AVX-512 Enhanced (512-bit ZMM, AVX512BW):
     - Evaluates 12 permutations simultaneously in 3 ZMM registers (512-bit SIMD).
     - Employs native 64-bit comparison masks (__mmask64) and byte shuffles across 4 boards per vector.
     - On CPUs lacking AVX-512, cleanly reported as [Not Supported by CPU].

SCORING & CALIBRATION:
  * Metric: MP/s (Mega-Positions per second = Evaluated Permutations / 1e6 / sec)
  * Formula: Score = Total Evaluated Positions / (Elapsed Seconds * 1e6)
  * Multi-threading: Thread-strided disjoint subspace search across all logical cores.

AIDA64 CALIBRATION REFERENCES:
  * AMD Ryzen 7 9700X HT Multi (16T) : 9,420 MP/s (DDR5-4800) / 9,836 MP/s (6000)
  * AMD Ryzen 7 9700X HT Single (1T) : 1,618 MP/s (DDR5-4800) / 1,611 MP/s (6000)
  * AMD Ryzen 7 8745HS Multi   (16T) : 3,290 MP/s (Lenovo 83K9 on battery)
  * Intel Core i5-1135G7 Multi    (8T) : 1,593 MP/s (Huawei BOD-WXX9)
