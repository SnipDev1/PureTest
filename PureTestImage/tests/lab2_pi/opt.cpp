#include <stdio.h>
#include <windows.h>
#include <locale.h>
#include <time.h>

// Вычисление числа Пи с использованием алгоритмической оптимизации (O(N))
// 1) Знак переключается за O(1) без вычисления степеней (sign = -sign)
// 2) Знаменатель вычисляется сложением вместо умножения (denom += 2.0)
// 3) Умножение на 4 вынесено за пределы цикла (однократно в конце)
DOUBLE calc_pi(ULONGLONG n)
{
	ULONGLONG a = clock(); // время начала работы подпрограммы
	DOUBLE s = 0.0;
	DOUBLE sign = 1.0;
	DOUBLE denom = 1.0;

	for (ULONGLONG i = 0; i < n; i++)
	{
		s += sign / denom;
		denom += 2.0;
		sign = -sign;
	}

	DOUBLE pi = 4.0 * s; // вынос умножения на 4 за пределы цикла
	ULONGLONG b = clock(); // время окончания работы подпрограммы
	ULONGLONG t = b - a;   // время работы подпрограммы
	printf_s("Затраченное время: %lf сек.\n", (DOUBLE)t / CLOCKS_PER_SEC);
	return pi;
}

int main()
{
	setlocale(LC_ALL, "");
	ULONGLONG n = 0; // количество членов ряда
	printf_s("Введите количество членов ряда: ");
	if (scanf_s("%llu", &n) != 1) return 1;
	DOUBLE pi = calc_pi(n);
	printf_s("pi = %.30lf\n", pi); // вывод результата с 30 знаками после запятой
	return 0;
}
