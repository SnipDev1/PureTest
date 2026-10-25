#include <stdio.h>
#include <windows.h>
#include <locale.h>
#include <time.h>

// Вычисление экспоненты с использованием алгоритмической оптимизации (схема Горнера, O(N))
DOUBLE ex(DOUBLE e, CHAR x, ULONGLONG n)
{
	ULONGLONG a = clock(); // время начала работы подпрограммы
	for (ULONGLONG i = n; i; i--)
		e = e * x / i + 1;
	ULONGLONG b = clock(); // время окончания работы подпрограммы
	ULONGLONG t = b - a;   // время работы подпрограммы
	printf_s("Затраченное время: %lf сек.\n", (DOUBLE)t / CLOCKS_PER_SEC);
	return e;
}

int main()
{
	CHAR x = 0; // степень экспоненты
	setlocale(LC_ALL, "");
	printf_s("Введите степень, в которую хотите возвести экспоненту: ");
	if (scanf_s("%hhd", &x) != 1) return 1;
	ULONGLONG n = 0; // количество членов ряда
	printf_s("Введите количество членов ряда: ");
	if (scanf_s("%llu", &n) != 1) return 1;
	DOUBLE e = 1; // Число e
	e = ex(e, x, n);
	printf_s("e^%hhd = %.30lf\n", x, e); // вывод результата с 30 знаками после запятой
	return 0;
}
