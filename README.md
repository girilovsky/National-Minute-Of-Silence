# National Minute of Silence Reminder (Загальнонаціональна хвилина мовчання о 09:00)

> Реалізація для Jira-задачі [II-5426](https://green-house-corp.atlassian.net/browse/II-5426) / [ITSD-94958](https://green-house-corp.atlassian.net/browse/ITSD-94958).

## 1. Огляд та бізнес-вимоги

Забезпечити щоденне автоматичне нагадування співробітникам про загальнонаціональну хвилину мовчання о **09:00** за місцевим часом для вшанування пам'яті загиблих захисників, захисниць та всіх жертв війни.

### Ключові функціональні вимоги:
- **Час запуску**: щодня о `09:00` за локальним часом пристрою.
- **Платформи**: корпоративні ноутбуки під керуванням **Windows** та **macOS**.
- **Міжпристроєва мілісекундна синхронізація**:
  - Усі ноутбуки в одному кабінеті, оупенспейсі або на онлайн-дзвінку цокають синхронно в одну мілісекунду (фазове блокування без какофонії та луни).
  - Фоновий **Pre-warming** о `08:59:50` (за 10 с до 09:00): процес у фоні без поспіху ініціалізує .NET/WPF, кешує аудіотрек у пам'ять із `Opacity = 0`.
  - Вбудований запит **NTP (SNTP UDP 123)** для автоматичного нівелювання розбіжності системного годинника ноутбуків (NTP Clock Skew).
  - Затримка відкриття: **<3 мілісекунди** в момент настання 09:00:00.000.
  - Режим **Catch-up**: якщо ноутбук розбудили із запізненням (між 09:00:00 та 09:00:55), він вирівнюється на найближчий цілий такт секунди, підлаштовує позицію аудіо та приєднується в фазі з іншими ноутбуками.
- **Поведінка інтерфейсу**:
  - Спливаюче вікно поверх інших вікон (`TopMost`).
  - Тривалість показу: **60 секунд** із плавним зворотним відліком (25 FPS).
  - Кнопка **"Зрозуміло"** (або клавіші `Esc`/`Space`/`Enter`) для закриття користувачем у будь-який момент.
  - **Не блокує роботу**: вікно не блокує систему, клавіатуру та введення паролів, не заважає дзвінкам.
  - **Time Guard**: суворий захист від хибного спрацьовування — дозволений інтервал 08:59:40 – 09:00:59. О 09:01:00 і пізніше сповіщення гарантовано блокується і НЕ відображається (хвилина мовчання офіційно завершена).
- **Аудіосупровід**:
  - Автентичний акустичний метроном 60.0 BPM (1.0000 с між тактами).
  - Знижена комфортна гучність: **25%** (`$defaultVolume = 0.25`).
  - Плавне затухання звуку (Audio Fade-Out) за **2.4 секунди** до кінця.
  - Швидке візуальне зникнення вікна (Window Opacity Fade-Out) за **0.2 секунди** до кінця.
  - Кнопка швидкого вимкнення звуку 🔊/🔇 та параметр `-NoSound`.

---

## 2. Структура проєкту

```
Projects/National-Minute-Of-Silence/
├── windows/
│   ├── Show-MinuteOfSilence.ps1                   # WPF-інтерфейс сповіщення з таймером, NTP та аудіо
│   ├── Register-MinuteOfSilenceTask.ps1           # Реєстрація щоденного завдання Windows Task Scheduler (08:59:50)
│   ├── Windows - National Minute of Silence Reminder.ps1  # All-in-one скрипт для Microsoft Intune (User context)
│   ├── Windows - Force time synchronization.ps1   # Intune-скрипт примусової синхронізації часу через W32Time / NTP (System context)
│   ├── metronome.mp3                              # Чистий калібрований метроном хвилини мовчання (60.0 BPM, 60 с)
│   └── 99_silent_m.mp3                            # Офіційний трек Веллез (метроном + оголошення)
├── macos/
│   ├── show-minute-of-silence.sh                  # macOS-скрипт (swiftDialog + osascript fallback + afplay)
│   ├── com.corp.minute-of-silence.plist           # LaunchAgent для запуску о 08:59 (фоновий прогрів)
│   ├── macOS - National Minute of Silence Reminder.sh     # All-in-one скрипт для Microsoft Intune (Root context)
│   ├── macOS - Force time synchronization.sh      # Intune-скрипт примусової синхронізації часу macOS (Root context)
│   ├── metronome.mp3                              # Чистий калібрований метроном хвилини мовчання (60.0 BPM, 60 с)
│   └── 99_silent_m.mp3                            # Офіційний трек Веллез
└── README.md
```

---

## 3. Архітектура міжпристроєвої синхронізації

```
08:59:50                     08:59:51                  09:00:00.000                09:00:57.6            09:00:60.0
   │                            │                            │                         │                      │
   ├── Task Scheduler старт     ├── NTP UDP 123 запит        ├── SpinWait завершено    ├── Audio Fade-Out     ├── Закриття
   │   (Powershell Hidden)      │   Визначення Clock Skew    │   Opacity = 1.0         │   (2.4 с затухання)  │   Stopwatch/Таймер
   ├── Ініціалізація WPF / .NET │   (time.google.com/windows)│   MediaPlayer.Play()    ├── Visual Fade-Out    └── Завершення
   └── Створення вікна          └── Розрахунок TargetInstant │   Stopwatch.Start()     │   (0.2 с прозорість)
       (Opacity = 0, невидиме)      (Target - Skew)          └── Лінія прогресу (25fps)└── Opacity = 0.0
```

1. **Pre-warming (08:59:50)**:
   - Усуває варіативність часу завантаження PowerShell та компіляції XAML (від 400 мс до 2500 мс на різних ноутбуках).
   - Вікно рендериться у відеопам'яті завчасно з `Opacity = 0`.
2. **NTP Clock Skew Compensation**:
   - Вбудована функція `Get-NtpClockOffsetMs` відправляє легкий 48-байтний SNTP-запит (UDP 123) до `time.google.com`, `time.windows.com`, `time.cloudflare.com` або `pool.ntp.org`.
   - За 50–100 мс визначається точне зміщення системного годинника Windows відносно атомарного UTC-часу.
   - Якщо системний годинник відстає або поспішає (наприклад, на ±1.2 с), цільовий момент старту автоматично коригується.
   - За відсутності мережі скрипт безпечно переходить на локальний системний час без затримок.
3. **Wall-Clock Millisecond Lock (SpinWait)**:
   - В останні 80 мілісекунд потік виконує високоточний `SpinWait(100)` замість `Thread.Sleep`, що усуває квантування планувальника Windows (15.6 мс).
   - Вікно миттєво робиться видимим (`Opacity = 1.0`), а звук стартує з точністю до <3 мілісекунд.
4. **Catch-up Mode**:
   - Якщо користувач відкрив кришку ноутбука о `09:00:15.350`, вікно не починає грати з нуля, а обчислює найближчий цілий такт (16-та секунда, 09:00:16.000).
   - Позиція аудіотреку виставляється на `16.0s`, вікно з'являється рівно о 09:00:16.000 синхронно з іншими пристроями в кімнаті.

---

## 4. Системна синхронізація часу через Intune

Для забезпечення загальної точності годинників на всіх пристроях організації створено спеціальні регламентні скрипти:

### 4.1. `Windows - Force time synchronization.ps1`
- **Контекст**: `RunAsAccount: system` (Intune Devices > Scripts > Windows).
- **Дія**:
  1. Вмикає службу `W32Time` та встановлює тип запуску `Automatic`.
  2. Налаштовує NTP-сервери: `pool.ntp.org,0x9 time.windows.com,0x9 time.google.com,0x9`.
  3. Встановлює інтервал опитування `SpecialPollInterval = 3600` (1 година замість стандартних 7 днів).
  4. Дозволяє миттєву фазову корекцію будь-якої величини (`MaxPhaseCorrection = 0xFFFFFFFF`).
  5. Виконує примусовий `w32tm /resync /force /nowait`.

### 4.2. `macOS - Force time synchronization.sh`
- **Контекст**: `Run as root` (Intune Devices > Scripts > macOS).
- **Дія**:
  1. Вмикає мережевий час: `/usr/sbin/systemsetup -setusingnetworktime on`.
  2. Призначає сервер `time.apple.com`.
  3. Виконує примусову синхронізацію через `sntp -sS time.apple.com`.
  4. Перезапускає демон `timed`.

---

## 5. Розгортання через Microsoft Intune

### 5.1. Стандарти назв об'єктів (відповідно до регламенту організації)
- **Основний скрипт Windows**: `Windows - National Minute of Silence Reminder`
- **Скрипт синхронізації часу Windows**: `Windows - Force time synchronization`
- **Основний скрипт macOS**: `macOS - National Minute of Silence Reminder`
- **Скрипт синхронізації часу macOS**: `macOS - Force time synchronization`
- **Цільова група**: `[Dist] Corporate Laptops` (або `[Dist] All Laptops`)
- **Група виключення (Exclusion)**: `[Dist] Minute of Silence - Exclusions`

### 5.2. Налаштування політики Windows у Intune
1. Перейдіть до **Microsoft Intune admin center** > **Devices** > **Scripts** > **Add** > **Windows 10 and later**.
2. **Basics**:
   - Name: `Windows - National Minute of Silence Reminder`
   - Description: `Daily reminder for the nationwide minute of silence at 09:00 (Jira II-5426)`
3. **Script settings**:
   - Script file: `windows/Windows - National Minute of Silence Reminder.ps1`
   - **Run this script using the logged on credentials**: `Yes`
   - **Enforce script signature check**: `No`
   - **Run script in 64 bit PowerShell Host**: `Yes`
4. **Assignments**:
   - **Included groups**: Додайте цільову групу корпоративних ноутбуків.
   - **Excluded groups**: Додайте групу виключень `[Dist] Minute of Silence - Exclusions`.

### 5.3. Налаштування політики macOS у Intune
1. Перейдіть до **Microsoft Intune admin center** > **Devices** > **Scripts** > **Add** > **macOS**.
2. **Basics**:
   - Name: `macOS - National Minute of Silence Reminder`
   - Description: `Daily reminder for the nationwide minute of silence at 09:00 (Jira II-5426)`
3. **Script settings**:
   - Script file: `macos/macOS - National Minute of Silence Reminder.sh`
   - **Run script as signed-in user**: `No` *(виконується від імені root для реєстрації LaunchAgent)*
   - **Hide script notifications on devices**: `Yes`
   - **Script frequency**: `Not configured` (одноразове встановлення LaunchAgent)
4. **Assignments**:
   - **Included groups**: Цільова група ноутбуків macOS.
   - **Excluded groups**: `[Dist] Minute of Silence - Exclusions`.

---

## 6. Механізм виключення (Exclusion Group)

Для користувачів чи пристроїв, для яких сповіщення може бути небажаним (наприклад, тестові стенди R&D, презентаційні ПК, переговорні кімнати Teams Rooms):
1. Створюється група Entra ID:
   - Назва: `[Dist] Minute of Silence - Exclusions`
   - Тип: Security Group
2. Група додається в поле **Excluded groups** в обох політиках Intune.

---

## 7. Інструкція з локального тестування

### Тестування на Windows:
```powershell
# Тестовий запуск (вирівнюється на початок наступної секунди, тривалість 10 с)
powershell.exe -ExecutionPolicy Bypass -File .\windows\Show-MinuteOfSilence.ps1 -Force -TestSeconds 10

# Тестовий запуск без звуку (3 секунди)
powershell.exe -ExecutionPolicy Bypass -File .\windows\Show-MinuteOfSilence.ps1 -Force -TestSeconds 3 -NoSound

# Перевірка реєстрації запланованого завдання (запуск о 08:59:50)
powershell.exe -ExecutionPolicy Bypass -File .\windows\Register-MinuteOfSilenceTask.ps1
Get-ScheduledTask -TaskName "National Minute of Silence Reminder"
```

### Тестування на macOS:
```bash
# Тестовий запуск сповіщення в активному терміналі
./macos/show-minute-of-silence.sh --force

# Перевірка статусу LaunchAgent
launchctl list | grep com.corp.minute-of-silence
```
