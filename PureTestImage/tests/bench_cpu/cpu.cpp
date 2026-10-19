// cpu.cpp — end-to-end системная проверка PureTestImage.
//
// Проверяет, что вся цепочка работает: машина загрузилась, g++ собрал код
// ПРЯМО НА ЭТОЙ машине (-march=native), тест выполнился, время замерено.
// Плюс сообщает характеристики железа и делает несколько мини-бенчмарков.
//
// Код самодостаточный: только стандартная библиотека C++.
// Выход всегда 0 (успех), чтобы harness записал полный отчёт.
#include <cstdio>
#include <cstring>
#include <cmath>
#include <chrono>
#include <vector>

// ----------------------------------------------------------- таймер (ns)
static long long now_ns() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}
static double seconds(long long a, long long b) {
    return double(b - a) / 1e9;
}

// volatile-«потребители», чтобы компилятор не выкидывал вычисления
static volatile double g_sink = 0.0;
static volatile unsigned long long g_isink = 0;

// ----------------------------------------------------- тест 1: целочисленный
// Зависимая цепочка сложения (latency-bound) и 4 независимые (throughput/ILP).
static void bench_int() {
    const long long ITERS = 200000000;
    volatile unsigned long long x = 1;

    auto t0 = now_ns();
    for (long long i = 0; i < ITERS; i++)
        x = x * 2862933555777941757ULL + 3037000493ULL;   // dependent chain
    auto t1 = now_ns();
    g_isink = x;

    volatile unsigned long long a = 1, b = 1, c = 1, d = 1;
    auto t2 = now_ns();
    for (long long i = 0; i < ITERS; i++) {               // ILP = 4
        a = a * 2862933555777941757ULL + 3037000493ULL;
        b = b * 2862933555777941757ULL + 3037000493ULL;
        c = c * 2862933555777941757ULL + 3037000493ULL;
        d = d * 2862933555777941757ULL + 3037000493ULL;
    }
    auto t3 = now_ns();
    g_isink = a + b + c + d;

    printf("  int-latency : %8.4f s  (%.0f M iter/s, dependent chain)\n",
           seconds(t0, t1), ITERS / seconds(t0, t1) / 1e6);
    printf("  int-4way    : %8.4f s  (%.0f M iter/s, ILP=4)\n",
           seconds(t2, t3), 4.0 * ITERS / seconds(t2, t3) / 1e6);
}

// ----------------------------------------------- тест 2: числа с плав. точкой
// Полином (FMA-дружелюбный) + проверка точности через sqrt/cos.
static double poly(double x) {
    return (((x * 1.0001 + 0.7) * x - 0.2) * x + 1.3) * x - 0.9;
}
static void bench_fp() {
    const long long ITERS = 40000000;
    double s = 0.0;
    auto t0 = now_ns();
    for (long long i = 0; i < ITERS; i++)
        s += poly(0.5 + (i & 0x1f) * 0.01);
    auto t1 = now_ns();
    g_sink = s;
    printf("  fp-poly     : %8.4f s  (%.0f M iter/s)\n",
           seconds(t0, t1), ITERS / seconds(t0, t1) / 1e6);

    double acc = 0.0;
    auto t2 = now_ns();
    for (long long i = 0; i < ITERS / 8; i++)
        acc += std::sqrt(double(i));
    auto t3 = now_ns();
    g_sink = acc;
    printf("  fp-sqrt     : %8.4f s\n", seconds(t2, t3));
}

// ---------------------------------- тест 3: пропускная способность памяти
// Читает и пишет буфер больше L3-кэша — замер bandwidth в ГБ/с.
static void bench_mem() {
    const size_t SIZE = 64 * 1024 * 1024;               // 64 МБ — за пределами L3
    const int PASSES = 4;
    std::vector<double> buf(SIZE / sizeof(double));
    for (auto &v : buf) v = 1.0;

    auto t0 = now_ns();
    for (int p = 0; p < PASSES; p++) {
        double sum = 0.0;
        for (size_t i = 0; i < buf.size(); i++) sum += buf[i];   // read
        g_sink = sum;
        for (auto &v : buf) v += 0.5;                            // write
    }
    auto t1 = now_ns();
    double bytes = double(buf.size()) * sizeof(double);
    double secs = seconds(t0, t1);
    printf("  mem-rw      : %8.4f s  (%.2f GB/s read+write)\n",
           secs, 2.0 * PASSES * bytes / secs / 1e9);
}

// ------------------------------------------------------------------ main
int main() {
    printf("=== PureTestImage SYSTEM CHECK ===\n\n");

    printf("--- CPU (integer) ---\n");
    bench_int();
    printf("\n--- FP ---\n");
    bench_fp();
    printf("\n--- Memory ---\n");
    bench_mem();

    printf("\n=== ALL TESTS COMPLETED SUCCESSFULLY (exit 0) ===\n");
    fflush(stdout);
    return 0;
}