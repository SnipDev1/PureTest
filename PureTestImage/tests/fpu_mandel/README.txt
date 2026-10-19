============================================================
PureTestImage: FPU Mandel Benchmark (AIDA64 v7+ Method)
============================================================

DESCRIPTION:
  Measures CPU 64-bit double-precision floating-point performance
  through the computation of the Mandelbrot fractal set (1024x1024).
  Outputs dual metrics: AIDA Baseline (AVX2 + FMA) and AVX-512 Enhanced
  for side-by-side architectural comparison.

DUAL VECTORIZATION MODES:
  1. AIDA Baseline (AVX2 + FMA, Method 36):
     - 16 FP64 double pixels per loop across 4 YMM registers (256-bit SIMD).
     - Standard AVX2 performance baseline across all modern x86-64 CPUs.
  2. AVX-512 Enhanced (AVX-512F, Method 43):
     - 32 FP64 double pixels per loop across 4 ZMM registers (512-bit SIMD).
     - Directly evaluates full 512-bit ZMM hardware throughput on CPUs with AVX-512F.
     - On CPUs lacking AVX-512, cleanly reported as [Not Supported by CPU].

SCORING & CALIBRATION:
  * Formula: Score = round(Total FPS * 209.863) (AIDA64 v7+ FinalWire normalization)
  * Multi-threading: Hardware-concurrency with zero-contention thread frames.

AIDA64 CALIBRATION REFERENCES:
  * AMD Ryzen 7 9700X (8C/16T Desktop)    : 104,887 (DDR5-4800) / 100,938 (6000)
  * AMD Ryzen 7 8745HS (8C/16T Mobile)     :  36,496 (Lenovo 83K9 on battery)
  * Intel Core i5-1135G7 (4C/8T Mobile)    :  13,898 (Huawei BOD-WXX9)
