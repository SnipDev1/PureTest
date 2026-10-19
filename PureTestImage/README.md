# PureTestImage

Загрузочный USB-образ для **оценки производительности x86-64 компьютеров** в
изолированной среде. Образ содержит минимальный Linux **с нативным компилятором
C++** (g++). Тест приходит на флешке как исходник, **компилируется на самой
тестируемой машине** (`-march=native` — под её конкретный CPU), запускается с
замером времени, отчёт пишется на экран и на ту же флешку.

- Одна флешка = образ + тесты + отчёты (раздел `DATADISK`, FAT32).
- Грузится и по **UEFI**, и по **legacy BIOS** (GRUB).
- Целевая машина не трогает свою ОС — весь прогон в изолированном live-окружении.
- Сборка — на Linux (Ubuntu Server) одним скриптом; с Windows запускается в одну
  команду. Тесты дозаписываются на флешку **без пересборки образа**.

> Почему не Docker/Buildroot: Docker — не изоляция (общий kernel с хостом).
> Buildroot официально не умеет нативный компилятор в образе (убрано с 2012.11,
> «you need a real distribution»). Минимальный Debian — «реальный дистрибутив»
> и при этом маленький.

---

## Структура репозитория

```
scripts/
  build.sh         главный скрипт сборки (запускается на Linux как root)
  ssh-build.bat    с Windows: синхронизация на сервер, сборка по SSH,
                   скачивание готового output/puretest.img
board/
  grub.cfg.in      загрузочное меню GRUB (BIOS + UEFI)
  overlay/         что попадает внутрь образа:
    opt/puretest/runner.sh    harness: меню, компиляция, замер, отчёт
    opt/puretest/README.txt   памятка «как класть тесты» (лежит и на флешке)
    etc/fstab                 tmpfs для /tmp, авто-монтирование DATADISK
    etc/systemd/system/puretest.service  автозапуск harness на tty1
tests/             готовые тесты; при сборке предзагружаются на DATADISK
    bench_cpu/     полный системный чек: CPU, FPU, память (главный тест)
    usb_check/     аудит шины USB, скоростей портов и проверка даунгрейда USB 3.0 -> 2.0
    usb_bench/     замер реальной скорости чтения/записи и IOPS USB-накопителя
    smoke_fib/     быстрый «дымовой» тест
    stdin_demo/    проверка передачи файла в stdin (run.stdin)
    fail_demo/     тест с ненулевым кодом возврата (проверка обработки сбоя)
    README.txt     памятка про добавление собственных тестов
```

---

## Сборка образа

### Требования к серверу сборки (Linux)

Нужен **Ubuntu Server 22.04 / 24.04** (или любой Debian/Ubuntu). Установить один раз:

```bash
sudo apt-get update
sudo apt-get install -y debootstrap rsync parted dosfstools \
     grub-pc-bin grub-efi-amd64-bin grub2-common
```

Потребуется ~3 ГБ свободного места. Сборка занимает 5–15 минут (первый раз
загружает пакеты Debian ~500 МБ).

---

### Вариант A — напрямую на Linux (без Windows)

```bash
git clone <URL репозитория>
cd PureTestImage
sudo bash scripts/build.sh
```

Готовый образ: `output/puretest.img`.

---

### Вариант B — с Windows через SSH

1. **Отредактируй** `scripts\ssh-build.bat` — в начале файла поставь свои данные:

```bat
set "REMOTE_USER=твой_логин"
set "HOST=адрес.сервера"
set "PORT=22"
set "REMOTE_DIR=~/PureTestImage"
```

2. **Запусти** `scripts\ssh-build.bat` (двойной клик или cmd).

Скрипт автоматически:
- проверяет SSH-соединение
- настраивает `sudo` без пароля (спросит пароль один раз, если не настроено)
- заливает исходники на сервер
- запускает сборку
- скачивает `output\puretest.img` обратно на Windows

**Требования:** SSH-доступ к серверу (по ключу или паролю), Windows 10/11.

---

### Размеры образа (переменные окружения)

По умолчанию образ **2.6 ГБ** (минимум для g++ и ядра). Кастомизация:

```bash
sudo -E IMG_SIZE=6G ROOT_SIZE=2G ESP_SIZE=128MiB bash scripts/build.sh
```

| Переменная | По умолчанию | Зачем |
|---|---|---|
| `IMG_SIZE` | `2.6G` | общий размер файла (флешка должна быть >= этого) |
| `ROOT_SIZE` | `1.5G` | корневой раздел; с g++ занято ~0.9 ГБ; не ниже 1.2G |
| `ESP_SIZE` | `64MiB` | EFI-раздел (GRUB нужен ~15 МБ) |
| `CUSTOM_PACKAGES` | `g++ make binutils time` | доп. пакеты (например `libomp-dev` для OpenMP) |
| `ROOT_PASS` | — | пароль root для консоли образа (опционально) |

Раздел `data` занимает остаток: `IMG_SIZE - ROOT_SIZE - ESP`.

---

## Запись на флешку

**Windows:** Rufus → выбрать `puretest.img` → режим **«DD image»**. Или Balena Etcher.

**Linux:** `sudo dd if=output/puretest.img of=/dev/sdX bs=4M status=progress`
(внимательно выбирайте `sdX` — это ваша флешка!).

Флешка перезаписывается целиком. Размер флешки >= `IMG_SIZE`.

> Secure Boot должен быть **выключен** на тестируемой машине — GRUB не подписан.

---

## Добавление тестов (без пересборки образа)

Тесты живут на разделе `DATADISK` (FAT32) — его видно в Windows как обычный том.

1. Вставить флешку в Windows.
   - Если раздел `DATADISK` **не получил букву**, выдать её через diskpart:
     ```
     diskpart
     list disk          # найти флешку по размеру, напр. Disk 4
     select disk 4
     list partition     # найти раздел DATADISK (~1 ГБ), напр. partition 4
     select partition 4
     set id=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
     assign letter=K
     exit
     ```
2. Создать `K:\tests\<имя>\` и положить туда файлы:
   - `run.sh` (необязательно) — bash-скрипт, если тест не компилируемый
   - `*.cpp` / `*.cc` / `*.cxx` — исходники (компилируются вместе)
   - `build.flags` (необязательно) — доп. флаги g++, одна строка
   - `run.args` (необязательно) — аргументы командной строки
   - `run.stdin` (необязательно) — файл, подаваемый в stdin
3. Готово — тест появится в меню при следующей загрузке. Никакой пересборки.

---

## Использование на целевой машине

1. Бут-меню → выбрать USB (`F12`/`F9`/`F11`/`Esc` зависит от производителя).
   Убедиться, что Secure Boot выключен.
2. GRUB-меню → первый пункт (benchmark). На tty1 появится меню `PURETESTIMAGE`:
   - список тестов из `DATADISK/tests/`
   - `[a]` — запустить **ВСЕ тесты** подряд (пакетный режим)
   - `[s]` — выйти в интерактивную **root-консоль** (bash)
   - `[r]` — перезагрузка (`reboot`)
   - `[p]` — выключение питания (`poweroff`)
   - выбор имени конкретного теста → компиляция `g++ -O2 -march=native` (или запуск `run.sh`) → N прогонов → отчёт
3. Результаты:
   - `DATADISK:\results\<машина>\<тест>-<время>\report.txt`
   - `DATADISK:\results\summary.tsv` — сводная таблица всех прогонов

### Автозапуск без клавиатуры (AUTORUN)

На `DATADISK` создать файл `AUTORUN` со строкой `ALL` (для прогона всех тестов) или с именем конкретного теста:

```
ALL
```
*(или `bench_cpu`)*

Машина загрузится, прогонит тесты и **сама выключится** (`poweroff`).

---

## Проверка без флешки (QEMU, на сервере)

```bash
sudo apt-get install -y qemu-system-x86 ovmf

# UEFI:
qemu-system-x86_64 -M q35 -bios /usr/share/ovmf/OVMF.fd -m 2G \
    -drive file=output/puretest.img,if=none,id=d,format=raw \
    -device ahci,id=sata -device ide-hd,drive=d,bus=sata.0 -nographic

# legacy BIOS: то же без -bios и без -M q35
```

---

## FAQ

- **Загрузка уходит сразу в Windows** — включён Secure Boot. Выключить в UEFI
  (Security → Secure Boot → Disable).
- **Тест не виден в меню** — убедиться, что папка с тестом есть в `DATADISK/tests/`
  и содержит хотя бы один `.cpp`/`.cc`/`.cxx` файл.
- **Windows не даёт букву разделу `DATADISK`** — использовать diskpart (см. выше).
- **Тест завис** — каждый прогон режется `timeout` (600 с по умолчанию).
- **Нужны библиотеки** (pthread, OpenMP) — добавить пакет в `CUSTOM_PACKAGES`
  при сборке, например `CUSTOM_PACKAGES="g++ make binutils time libomp-dev"`.
- **Нет интернета на целевой машине** — это цель, всё нужное уже в образе.
