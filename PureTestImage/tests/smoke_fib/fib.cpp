// fib.cpp — маленький «дымовой» тест: быстро, без доп. файлов.
// Проверяет, что g++ собрал и программа выполнилась. Вычисляет числа
// Фибоначчи рекурсивно на небольшой глубине (проверка call-стеков).
#include <cstdio>

long long fib(int n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

int main() {
    // fib(40) ~ 1–2 сек на современных машинах
    long long r = fib(40);
    std::printf("fib(40) = %lld\n", r);
    std::printf("smoke test OK (exit 0)\n");
    return 0;
}