// echo_stdin.cpp — проверка чтения run.stdin (файл передаётся в stdin теста).
// Просто выводит, сколько байт получено, и их sha-подобную сумму.
#include <cstdio>
#include <cstdint>

int main() {
    unsigned long long bytes = 0, sum = 0;
    int c;
    while ((c = std::getchar()) != EOF) {
        bytes++;
        sum = sum * 131 + (unsigned)c;   // дешёвый полиномиальный «сверток»
    }
    std::printf("stdin bytes=%llu checksum=%llu\n", bytes, sum);
    std::printf("stdin test OK (exit 0)\n");
    return 0;
}