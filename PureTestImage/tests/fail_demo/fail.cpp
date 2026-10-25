// fail_demo.cpp — намеренно возвращает ненулевой код (41).
// Проверяет, что harness правильно помечает упавшие тесты в отчёте.
#include <cstdio>

int main() {
    std::printf("this test deliberately fails with code 41\n");
    return 41;
}