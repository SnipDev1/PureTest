#include <stdio.h>
#include <locale.h>
#include <windows.h>
#include <time.h>

// Вычисление n-го слагаемого ряда Лейбница без алгоритмической оптимизации
// Формула слагаемого: 4 * (-1)^n / (2*n + 1)
// (-1)^n вычисляется перемножением в цикле (общая сложность алгоритма O(N^2))
DOUBLE summand(ULONGLONG n)
{
	DOUBLE sign = 1.0;
	for (ULONGLONG i = 1; i <= n; i++)
		sign *= -1.0;
	return 4.0 * sign / (2.0 * n + 1.0);
}

// Вычисление суммы ряда по первым n слагаемым
DOUBLE calc_pi(ULONGLONG n)
{
	ULONGLONG a = clock(); // время начала работы подпрограммы
	DOUBLE pi = 0.0;
	for (ULONGLONG i = 0; i < n; i++)
		pi += summand(i);
	ULONGLONG b = clock(); // время окончания работы подпрограммы
	ULONGLONG t = b - a;   // время работы подпрограммы
	printf_s("Затраченное время: %lf сек.\n", (DOUBLE)t / CLOCKS_PER_SEC);
	return pi;
}

int main()
{
	setlocale(LC_ALL, "");
	ULONGLONG n = 0;
	printf_s("Введите число членов ряда: ");
	if (scanf_s("%llu", &n) != 1) return 1;
	DOUBLE pi = calc_pi(n);
	printf_s("pi = %.30lf\n", pi);
	return 0;
}
