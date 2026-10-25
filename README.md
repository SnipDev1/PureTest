# PureTest — Платформа изолированного тестирования и бенчмаркинга ПК

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Linux%20x86--64-blue.svg" alt="Platform">
  <img src="https://img.shields.io/badge/Boot-UEFI%20%7C%20Legacy%20BIOS-brightgreen.svg" alt="Boot Mode">
  <img src="https://img.shields.io/badge/Secure%20Boot-Supported%20(shim)-success.svg" alt="Secure Boot">
  <img src="https://img.shields.io/badge/Compiler-Native%20GCC%2012%2B-orange.svg" alt="Compiler">
  <img src="https://img.shields.io/badge/License-MIT-purple.svg" alt="License">
</p>

**PureTest** — легковесный автономный загрузочный USB-образ (Live Linux) для **чистого аппаратного и алгоритмического тестирования x86-64 компьютеров и ноутбуков**. 

В отличие от стандартных ОС (Windows, Ubuntu) или контейнеров (Docker), PureTest обеспечивает **100% изоляцию железа**:
- Никаких фоновых сервисов, телеметрии, антивирусов или планировщиков, искажающих замеры времени.
- Встроенный нативный компилятор C++ (`g++`): исходный код компилируется **прямо на тестируемой машине** с флагом `-march=native`, задействуя специфичные процессорные инструкции (AVX2, AVX-512, FMA, BMI2).
- Раздел `DATADISK` (FAT32) доступен в Windows, macOS и Linux как обычная флешка: для добавления тестов и чтения отчётов не требуется пересборка образа.

---

## ⚡ Ключевые возможности

### 1. Чистая аппаратная среда
- **UEFI & Legacy BIOS**: универсальная загрузка на любых ПК и серверах.
- **Поддержка Secure Boot**: ядро и GRUB подписаны официальным сертификатом Microsoft через Debian `shim`. Отключать Secure Boot в BIOS не требуется.
- **Фиксация частот**: автоматическое включение CPU-гувернёра `performance` на всех ядрах для стабильности замеров.

### 2. Матрица степеней оптимизации (AO — Automatic Optimization)
Тестирование исходного кода по всем уровням оптимизации компилятора GCC в один клик (`[ao]`):
- `O0`: `-O0 -fno-builtin` — базовый уровень без оптимизаций (чистый Baseline/Debug).
- `O1`: `-O1` — базовая оптимизация.
- `O2`: `-O2 -march=native` — стандартная производственная оптимизация под архитектуру CPU.
- `O3`: `-O3 -march=native` — агрессивная векторизация циклов и разворачивание.
- `Ofast`: `-Ofast -march=native -flto` — экстремальная скорость (Link-Time Optimization, быстрая математика).
- Автоматический расчёт коэффициента ускорения (**Speedup vs O0**).

### 3. Режим лабораторных работ `[lab]` и экспорт в Microsoft Word
Специализированный режим для университетских лабораторных работ по архитектуре ЭВМ:
- Сравнение неоптимизированной (`base.cpp`, $O(N^2)$) и оптимизированной (`opt.cpp`, $O(N)$) версий алгоритма.
- Прогон по сетке параметров из `inputs.txt` (поддерживаются как двухпараметрические тесты $(X, N)$, так и однопараметрические $(N)$).
- Автоматическая оценка точности вычислений и сравнение с математическим эталоном ($\text{Погрешность} = |V_{\text{calc}} - V_{\text{ref}}|$).
- Предотвращение зависаний: при $N > 1\,000\,000$ для $O(N^2)$ прогон `base.cpp` автоматически пропускается (`-`), как в отчётах.
- **Экспорт в Microsoft Word**: генерация отчётных таблиц в формате `.tsv` (Tab-Separated Values). При копировании текста и нажатии **Ctrl+V в документе Word** текст мгновенно преобразуется в **готовую нативную таблицу** с границами и столбцами!

### 4. Паспорт аппаратной архитектуры (`puretest-hw` / `[hw]`)
Автоматический аудит аппаратной конфигурации машины:
- Процессор: точная модель, базовая и максимальная частота буста (AMD Precision Boost / Intel Turbo Boost).
- Ядра и потоки: число физических ядер и логических процессоров.
- Топология кэш-памяти: L1 Data, L1 Instruction, L2, L3 (размеры и организация).
- Оперативная память: объём, частота и тип (DDR4 / DDR5) через DMI/sysfs.
- Скорость USB-накопителя: линейная запись/чтение и случайные 4K IOPS.

### 5. Слой совместимости с Windows / Visual Studio (`windows.h`)
Студенческий код, написанный в Microsoft Visual Studio под Windows, компилируется в PureTest без единой модификации:
- Заголовок `/usr/local/include/windows.h` встроен в образ.
- Поддерживаются типы MSVC: `DOUBLE`, `ULONGLONG`, `LONGLONG`, `CHAR`, `DWORD`, `BOOL`, `LARGE_INTEGER`.
- Безопасные CRT-функции: `printf_s`, `scanf_s`, `sprintf_s`, `strcpy_s`.
- Системные таймеры: `clock()`, `QueryPerformanceCounter`, `QueryPerformanceFrequency`, `GetTickCount`, `Sleep`.

### 6. Автоматическое обновление флешки в 1 клик (`update_usb.sh`)
Больше не нужно каждый раз перезаписывать образ на флешку!
Скрипт `update_usb.sh`:
- Автоматически находит разделы флешки (`EFIBOOT`, `PUREROOT`, `DATADISK`).
- Проверяет и исправляет целостность файловой системы FAT32 (`fsck.vfat -a`).
- Синхронизирует обновленный раннер, заголовок `windows.h`, утилиту `puretest-hw` и новые тесты.
- Сохраняет все накопленные результаты и логи на `DATADISK`.

### 7. Удаленная кроссплатформенная сборка по SSH
Если у вас Windows или слабый ноутбук, образ собирается на удаленном сервере (Ubuntu/Debian) в одну команду:
- **На Linux / macOS**: `./ssh_build.sh`
- **На Windows**: `ssh-build.bat`

---

## 📁 Структура проекта

```text
PureTest/
├── README.md                      # Главное руководство по проекту
├── LICENSE                        # Лицензия MIT
├── .gitattributes                 # Нормализация LF для bash-скриптов
├── .gitignore                     # Исключение временных файлов и секретов
├── ssh_build.sh                   # Скрипт сборки по SSH (Linux/macOS)
├── ssh-build.bat                  # Скрипт сборки по SSH (Windows)
├── update_usb.sh                  # Авто-обновление подключенной флешки
├── PureTestImage/                 # Основной исходный пакет PureTest
│   ├── board/                     # Конфигурация загрузчика и системного оверлея
│   │   ├── grub.cfg.in            # Меню GRUB (BIOS + UEFI)
│   │   └── overlay/               # Файлы, монтируемые в корень live-системы
│   │       ├── opt/puretest/      # Движок раннера (runner.sh) и памятка
│   │       ├── usr/local/bin/     # Утилиты (puretest-hw, puretest-log, etc.)
│   │       └── usr/local/include/ # Заголовок windows.h для совместимости с MSVC
│   ├── scripts/
│   │   ├── build.sh               # Главный скрипт локальной сборки образа (Linux root)
│   │   ├── ssh_build.sh           # Реализация удаленной сборки по SSH
│   │   ├── ssh-build.bat          # Реализация удаленной сборки под Windows
│   │   ├── ssh-build.env.example  # Шаблон настроек сервера SSH
│   │   └── update_usb.sh          # Скрипт обновления готовой флешки
│   ├── tests/                     # Готовые наборы тестов (копируются на DATADISK)
│   │   ├── bench_cpu/             # Комплексный тест: CPU, FPU, память (системный чек)
│   │   ├── cpu_checkmate/         # AVX2 целочисленный тест (битовые доски, перестановки)
│   │   ├── fpu_mandel/            # AVX2 FPU тест (множество Мандельброта, double SIMD)
│   │   ├── lab1_exp/              # Лабораторная: e^x (base O(n^2) vs opt O(n))
│   │   ├── lab2_pi/               # Лабораторная: число Пи (ряд Лейбница, O(n^2) vs O(n))
│   │   ├── usb_bench/             # Замер реальной скорости чтения/записи флешки
│   │   ├── usb_check/             # Проверка портов и даунгрейда USB 3.0 -> 2.0
│   │   ├── smoke_fib/             # Быстрый тест корректности окружения
│   │   ├── stdin_demo/            # Демонстрация подачи данных через run.stdin
│   │   └── fail_demo/             # Тест обработки кодов ошибок
│   ├── config.env                 # Настройки по умолчанию (AO_LEVEL, RUNS, TIMEOUT)
│   └── run_list.txt               # Очередь тестов для пакетного запуска
└── tests/                         # Симлинк на PureTestImage/tests/
```

---

## 🚀 Быстрый старт

### Вариант 1: Сборка образа по SSH (рекомендуется для Windows и macOS)

1. Создайте файл настроек `PureTestImage/scripts/ssh-build.env` на основе шаблона:
   ```bash
   cp PureTestImage/scripts/ssh-build.env.example PureTestImage/scripts/ssh-build.env
   ```
2. Укажите реквизиты вашего сервера Ubuntu (IP-адрес, пользователь, порт):
   ```ini
   REMOTE_USER=ubuntu
   HOST=192.168.1.100
   PORT=22
   ```
3. Запустите сборку:
   - **Linux / macOS**: `./ssh_build.sh`
   - **Windows**: двойной клик по `ssh-build.bat` (или запуск из cmd)

Скрипт автоматически подключится к серверу, настроит окружение, соберёт образ и скачает `output/puretest.img` на ваш компьютер.

---

### Вариант 2: Локальная сборка на Linux

Требуется **Ubuntu 22.04 / 24.04** или Debian 12:

```bash
# 1. Установка необходимых утилит
sudo apt-get update
sudo apt-get install -y debootstrap rsync parted dosfstools grub-pc-bin grub-efi-amd64-bin grub2-common

# 2. Сборка образа
cd PureTestImage
sudo bash scripts/build.sh
```

Готовый файл: `output/puretest.img`.

---

## 💾 Запись на USB-флешку

- **Windows**: Откройте **Rufus** → выберите файл `puretest.img` → в диалоговом окне выберите режим **«Запись в режиме DD-образа»** (или используйте **Balena Etcher**).
- **Linux**:
  ```bash
  sudo dd if=output/puretest.img of=/dev/sdX bs=4M status=progress conv=fsync
  ```
  *(где `/dev/sdX` — целевой USB-накопитель; будьте внимательны при выборе диска!)*

---

## 🔄 Обновление готовой флешки (`update_usb.sh`)

Если вы изменили код тестов, добавили лабораторную работу или обновили скрипты, перезаписывать флешку через Rufus **не нужно**:

1. Вставьте вашу готовую флешку PureTest в компьютер.
2. Выполните:
   ```bash
   ./update_usb.sh
   ```
3. Скрипт безопасно обновит системный оверлей на `PUREROOT` и синхронизирует тесты на `DATADISK`.

---

## 🖥️ Меню управления на целевом ПК

При загрузке с флешки на экране появится интерактивное меню PureTest:

```text
==========================================================
PURETESTIMAGE  (Lenovo_ThinkPad | 16 cores | AO: O2)
Available tests:
  * bench_cpu
  * cpu_checkmate
  * fpu_mandel
  * lab1_exp  [lab benchmark (base vs opt)]
  * lab2_pi   [lab benchmark (base vs opt)]
  * usb_bench
  * usb_check

Actions:
  [a]   Run ALL tests (current AO: O2)
  [ao]  Run test across ALL AO levels (O0..Ofast comparison matrix)
  [lab] Run Lab Benchmark (base.cpp vs opt.cpp comparison matrix for Word)
  [hw]  Generate Hardware Architecture Profile (machine_specs.tsv)
  [o]   Change AO (Optimization) level [Current: O2]
  [l]   Run test list from run_list.txt / AUTORUN
  [s]   Drop to interactive root shell
  [c]   Clear screen
  [q]   Exit to shell
  [r]   Reboot machine
  [p]   Power off
Or type: <testname> [AO]  (e.g. 'bench_cpu', 'lab lab1_exp', 'hw', 'ao bench_cpu')
----------------------------------------------------------
puretest [O2]> 
```

### Автоматический запуск без клавиатуры (AUTORUN)
Если вам нужно протестировать партию ПК без монитора/клавиатуры:
1. Создайте на разделе `DATADISK` файл `AUTORUN` со словом `ALL` (или именем конкретного теста).
2. Подключите флешку к ПК и включите питание.
3. Система загрузится, автоматически выполнит тесты, сохранит результаты и выключит питание (`poweroff`).

---

## 📊 Экспорт результатов в Microsoft Word

На разделе `DATADISK/results/` сохраняются готовые файлы отчётов:

1. **`accuracy_table.tsv`** — таблица оценки точности (значения $x$, $n$, результат без оптимизации, с оптимизацией, эталон, погрешность).
2. **`timing_table.tsv`** — матрица времени работы и процент выигрыша алгоритмической оптимизации по уровням O0, O1, O2.
3. **`machine_specs.tsv`** — паспорт архитектуры ПК (CPU, частоты, кэш L1-L3, ОЗУ, USB).

> **💡 Быстрая вставка**: Откройте любой `.tsv` файл в Блокноте (Notepad), нажмите `Ctrl+A` -> `Ctrl+C`, затем откройте документ в Microsoft Word и нажмите `Ctrl+V`. Word автоматически создаст готовую форматированную таблицу со всеми столбцами и строками!

---

## 📜 Лицензия

Проект распространяется под открытой лицензией [MIT](LICENSE). Разрешается свободное использование в учебных, исследовательских и коммерческих целях.
