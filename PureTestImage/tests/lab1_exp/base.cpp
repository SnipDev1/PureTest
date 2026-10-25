#include <stdio.h>
#include <locale.h>
#include <windows.h>
#include <time.h>

// Вычисление n-го слагаемого x^N / N! без алгоритмической оптимизации (O(N^2) общая сложность)
DOUBLE summand(CHAR x, ULONGLONG N)
{
	DOUBLE s = 1;
	for (ULONGLONG i = 1; i <= N; i++)
		s = s * x / i;
	return s;
}

// Вычисление суммы ряда Тейлора
DOUBLE ex(DOUBLE e, CHAR x, ULONGLONG n)
{
	ULONGLONG a = clock();
	for (ULONGLONG i = 1; i <= n; i++)
		e += summand(x, i);
	ULONGLONG b = clock();
	ULONGLONG t = b - a;
	printf_s("Затраченное время: %lf сек.\n", (DOUBLE)t / CLOCKS_PER_SEC);
	return e;
}

int main()
{
	setlocale(LC_ALL, "");
	CHAR x = 0;
	printf_s("Введите показатель степени: ");
	if (scanf_s("%hhd", &x) != 1) return 1;
	ULONGLONG n = 0;
	printf_s("Введите число членов ряда: ");
	if (scanf_s("%llu", &n) != 1) return 1;
	DOUBLE e = 1;
	e = ex(e, x, n);
	printf_s("e^%hhd = %.30lf\n", x, e);
	return 0;
}
