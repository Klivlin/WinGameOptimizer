# WinGameOptimizer

GUI-утилита на PowerShell (Windows Forms) для тюнинга Windows 10/11 под игры — Valorant, CS2/CS:GO, Dota 2 и другие. Все действия обратимы: перед применением создаётся бэкап затронутых настроек, есть кнопки восстановления.

A PowerShell GUI (Windows Forms) utility for tuning Windows 10/11 for gaming — Valorant, CS2/CS:GO, Dota 2 and others. Every action is reversible: a backup of affected settings is created before applying, with restore buttons provided.

> ⚠️ Запускать от имени администратора. Перед первым применением рекомендуется создать точку восстановления системы.
> ⚠️ Run as Administrator. Creating a Windows System Restore point before first use is recommended.

---

## Запуск / Usage

```powershell
powershell -ExecutionPolicy Bypass -File WinGameOptimizer.ps1
```

Скрипт сам запросит повышение прав (UAC), если его не хватает.
The script requests elevation (UAC) automatically if not already running as admin.

---

## Что НЕ делает скрипт / What this script will NOT do

- По умолчанию не трогает антивирус/Защитник Windows (Defender) и брандмауэр. Отключение Defender — отдельная опция вкладки «Advanced (риск)» с подтверждением.
  Does not touch antivirus/Defender or the firewall by default. Disabling Defender is an opt-in option on the Advanced tab with confirmation.
- Не отключает Windows Update полностью (только фоновые задачи телеметрии/CEIP, не сам механизм обновлений безопасности).
  Does not fully disable Windows Update (only background telemetry/CEIP scheduled tasks, not the security-update mechanism itself).
- Не удаляет античит-процессы или системные компоненты, необходимые для работы игр (vgc.exe, EasyAntiCheat и т.п. не трогаются).
  Does not touch anti-cheat processes or components required for games to run (vgc.exe, EasyAntiCheat, etc. are left untouched).

---

## Функции / Features

### 1. Вкладка «Питание» / Power tab
| Настройка (RU) | Setting (EN) | Эффект |
|---|---|---|
| Ultimate Performance план питания | Ultimate Performance power plan | Убирает троттлинг CPU/энергосберегающие переходы, убирает скрытый план питания Windows |
| Отключить USB selective suspend | Disable USB selective suspend | USB-устройства (мышь/геймпад) не "засыпают", снижает случайные микро-лаги |
| Отключить core parking | Disable core parking | Все логические ядра CPU остаются активными, снижает задержку пробуждения ядра при нагрузке |

> **Процессоры AMD X3D / X3D CPUs:** скрипт определяет X3D автоматически. Вместо Ultimate Performance включается «Сбалансированная» (драйвер 3D V-Cache сам выбирает CCD для игры), а отключение core parking пропускается.
> The script auto-detects X3D CPUs: Balanced plan is used instead of Ultimate Performance and core-parking tweak is skipped.

### 2. Вкладка «GPU / Дисплей» / GPU & Display tab
> **Двухчиплетные X3D (7900X3D / 7950X3D / 9900X3D / 9950X3D):** отключение Game Bar пропускается — драйвер 3D V-Cache использует его для распознавания игр и выбора CCD.
> On dual-CCD X3D CPUs the Game Bar tweak is skipped: the 3D V-Cache driver relies on it to detect games and pick the CCD.

| RU | EN | Эффект |
|---|---|---|
| Hardware-Accelerated GPU Scheduling (HAGS) | same | Планирование GPU на уровне драйвера вместо CPU-диспетчера, снижает задержку рендера на поддерживаемых GPU |
| Отключить Game DVR / Xbox Game Bar overlay | Disable Game DVR / Xbox Game Bar overlay | Убирает фоновую запись/оверлей, разгружает GPU/CPU во время игры |
| Приоритет GPU/CPU для игр (MMCSS "Games") (выкл. по умолчанию) | Game-priority MMCSS profile (off by default) | MMCSS в основном влияет на аудиопотоки; для игр эффект спорный — включайте и сравнивайте |
| Визуальные эффекты "Лучшее быстродействие" (выкл. по умолчанию) | "Best performance" visual effects (off by default) | Отключает анимации Windows, немного освобождает CPU/GPU |

### 3. Вкладка «Сеть» / Network tab
| RU | EN | Эффект |
|---|---|---|
| Отключить Network Throttling Index | Disable Network Throttling Index | Снимает искусственное ограничение пропускной способности мультимедиа-трафика в MMCSS |
| Отключить алгоритм Нагла (TCPNoDelay) (выкл. по умолчанию) | Disable Nagle's algorithm (TCPNoDelay) (off by default) | Влияет только на TCP; большинство шутеров работает по UDP, поэтому польза мала |
| Flush DNS + сброс Winsock (выкл. по умолчанию) | Flush DNS + reset Winsock (off by default) | Устраняет повреждённые сетевые настройки/DNS-кэш, может помочь при высоком пинге |

### 4. Вкладка «Система» / System tab
| RU | EN | Эффект |
|---|---|---|
| Остановить фоновые службы (SysMain, WSearch, DiagTrack, dmwappushservice, MapsBroker, lfsvc, RetailDemo, WerSvc) | Stop background services (same list) | Снижает фоновую нагрузку на CPU/диск от индексации, телеметрии, геолокации и т.д. |
| Отключить фоновые задачи планировщика (телеметрия, CEIP, карты, отзывы) | Disable background scheduled tasks (telemetry, CEIP, maps, feedback) | Убирает периодические фоновые "просыпания" системы |
| Отключить фоновые UWP-приложения | Disable background UWP apps | UWP-приложения из Store не работают в фоне и не тратят ресурсы |
| Отключить энергосбережение сетевой карты | Disable NIC power saving | NIC не уходит в低power-режим, снижает сетевые микро-лаги/джиттер |
| Отключить гибернацию (выкл. по умолчанию) | Disable hibernation (off by default) | Освобождает место на диске (убирает hiberfil.sys) |
| Очистить temp/кэш/корзину | Clean temp/cache/recycle bin | Освобождает место, убирает мусорные файлы, которые может сканировать антивирус/индексатор (Prefetch не трогается) |
| Win32PrioritySeparation = 18 (выкл. по умолчанию) | same (off by default) | Фиксированный длинный квант планировщика: фоновый поток реже вытесняет игровой. Эффект зависит от системы — тестируйте |

### 5. Вкладка «Мышь / Инпут-лаг» / Mouse & Input-lag tab
| RU | EN | Эффект |
|---|---|---|
| Отключить акселерацию мыши (Enhance Pointer Precision) | Disable mouse acceleration (Enhance Pointer Precision) | Линейное, предсказуемое перемещение курсора — критично для шутеров |
| Уменьшить буфер очереди мыши/клавиатуры | Reduce mouse/keyboard input queue size | Меньше буферизация ввода драйвером (`mouclass`/`kbdclass`) — ниже задержка отклика |
| Отключить энергосбережение HID-устройств | Disable HID device power saving | Мышь/клавиатура не "просыпаются" с задержкой после простоя |
| **[Продвинуто]** Привязка IRQ мыши/клавиатуры к выбранному ядру CPU | **[Advanced]** Pin mouse/keyboard IRQ to a chosen CPU core | Прерывания устройства обрабатываются выделенным ядром, не конкурируя с ядром, занятым игрой/рендером — снижает input-джиттер |
| **[Эксперимент]** Принудительный MSI-режим прерываний для HID | **[Experimental]** Force MSI interrupt mode for HID devices | MSI эффективнее классических line-based прерываний; риск — код 10 в Диспетчере устройств, если драйвер не поддерживает |

Перед изменением IRQ affinity / MSI создаётся бэкап соответствующей ветки реестра устройства (`InputDeviceBackups`), доступно восстановление одной кнопкой.

Before changing IRQ affinity / MSI mode, the relevant device registry branch is backed up (`InputDeviceBackups`), restorable with one button.

### 6. Вкладка «Advanced (риск)» / Advanced (risk) tab
| RU | EN | Эффект |
|---|---|---|
| | Отключить Spectre/Meltdown mitigations (выкл. по умолчанию, с отдельным подтверждением) | Disable Spectre/Meltdown mitigations (off by default, separate confirmation) | Заметный прирост в CPU-bound сценариях, но снижает защиту процессора от атак по сторонним каналам |
| Отключить Microsoft Defender (выкл. по умолчанию, с отдельным подтверждением и кнопкой «Включить обратно») | Disable Microsoft Defender (off by default, confirmation + one-click re-enable) | Убирает фоновые проверки файлов в реальном времени; прирост обычно небольшой, риски серьёзные — см. ниже |

#### Риски отключения Defender / Defender risks
- ПК остаётся **без антивируса**: не блокируются вирусы, майнеры, стилеры паролей/аккаунтов, шифровальщики. / The PC has **no antivirus** protection.
- Главный путь заражения у геймеров — читы, моды, «кряки» и сторонние установщики. / Cheats, mods and cracks are the main infection vector.
- Теряется защита от вредоносных скриптов, макросов и подменённых загрузок. / No protection from malicious scripts and tampered downloads.
- Нужно заранее вручную выключить «Защиту от подделки» (Tamper Protection), иначе Windows откатит изменения; скрипт сам её не отключает и сообщит об этом. / Tamper Protection must be turned off manually first.
- Обновления Windows могут включить Defender обратно; Центр безопасности будет показывать предупреждения; часть античитов/приложений могут сообщать о небезопасной конфигурации. / Windows updates may re-enable it; Security Center will warn.
- Полное удаление Defender **не выполняется**: на нём завязаны другие компоненты Windows. Используется отключение политиками и `Set-MpPreference`, оно обратимо кнопкой «Включить Defender обратно» (удаляет политики и возвращает параметры по умолчанию). / Defender is disabled, not uninstalled, and can be re-enabled with one click.
- Рекомендация: отключайте только при наличии другого антивируса или на ПК, который используется исключительно для игр, и не запускайте непроверенные файлы. / Disable only if you have another AV or a games-only PC.

### 7. Вкладка «Автозагрузка» / Startup tab
Показывает реальный список автозапуска (реестр `Run` HKCU/HKLM + папка Startup). Выбранные пункты **отключаются** (перемещаются в бэкап, не удаляются) — кнопка восстанавливает всё обратно.

Shows the actual startup list (registry `Run` keys + Startup folder). Checked items are **disabled** (moved to a backup, not deleted) — a button restores everything back.

### 8. Вкладка «Debloat (приложения)» / Debloat (apps) tab
Список предустановленных UWP-приложений (3D Builder, Skype, Solitaire, Feedback Hub, Карты, Погода/Новости Bing, Zune Music/Video, Clipchamp, To-Do и др.) с чекбоксами на удаление, включая удаление provisioned-пакета (чтобы не переустанавливался для новых профилей).

A checklist of preinstalled UWP apps (3D Builder, Skype, Solitaire, Feedback Hub, Maps, Bing Weather/News, Zune Music/Video, Clipchamp, To-Do, etc.) to remove, including the provisioned package (so it won't reinstall for new user profiles).

**Важно / Important:** Windows не поддерживает автоматический откат удаления приложений — список удалённого сохраняется в лог-файл, восстановление только переустановкой из Microsoft Store.
Windows has no built-in rollback for app removal — removed package names are logged to a file; restoring means reinstalling from the Microsoft Store.

### 9. Вкладка «Профиль игры» / Game profile tab
Выбор игры (Valorant / CS2 / CS:GO / Dota 2) и запуск фонового мониторинга процесса: при обнаружении игрового .exe ему автоматически выставляется приоритет `High` и affinity на все логические ядра. Анти-чит процессы не трогаются.

Select a game (Valorant / CS2 / CS:GO / Dota 2) and start a background process monitor: when the game's .exe is detected, it automatically gets `High` priority and affinity across all logical cores. Anti-cheat processes are left untouched.

---

## Чего оптимизатор намеренно НЕ делает / What it deliberately does not do

По итогам сравнения разборов по оптимизации Windows (сходятся не все, спорные пункты вынесены в «выкл. по умолчанию»):

- не удаляет Windows Defender (ломает связанные компоненты); отключение — только отдельной опцией с рисками и обратным включением;
- не отключает HPET и не лезет в `bcdedit` таймеры;
- не меняет TCP autotuning и не применяет «TCP Optimizer»-твики (игры работают по UDP);
- не чистит standby-список и не ставит «очистители памяти» (рост hard page faults и статтеров);
- не раскидывает процессы по ядрам и не меняет Ideal Processor потоков (только affinity прерываний устройств ввода, по желанию);
- не отключает устройства в диспетчере без разбора.

Спорные темы (тестируйте на своей системе): HAGS (по умолчанию включается), Игровой режим Windows (не трогается), режим питания (на AMD/X3D — «Сбалансированная»), `Win32PrioritySeparation`.

---

## Бэкап и восстановление / Backup & restore

- **Создать бэкап** — снимок текущей схемы питания, затронутых веток реестра и состояния служб (`%USERPROFILE%\WinGameOptimizer_Backups\<timestamp>`).
  **Create backup** — snapshot of the current power scheme, affected registry branches and service states.
- **Применить выбранное** — автоматически создаёт бэкап перед применением.
  **Apply selected** — automatically creates a backup before applying.
- **Восстановить из бэкапа** — откатывает схему питания, реестр, службы, автозагрузку и настройки устройств ввода из последнего бэкапа.
  **Restore from backup** — rolls back power scheme, registry, services, startup items and input-device settings from the latest backup.
- Отдельная кнопка восстановления для автозагрузки (вкладка «Автозагрузка») и для устройств ввода (вкладка «Мышь / Инпут-лаг»).
  Separate restore buttons exist for startup items (Startup tab) and input devices (Mouse/Input-lag tab).

---

## Честно о результатах / Honest expectations

Эти твики снижают фоновую нагрузку системы, делают frame-time более стабильным и уменьшают задержку ввода/сети. Они **не заменяют** апгрейд железа и не дают гарантированный кратный прирост FPS в GPU-bound сценариях — основной прирост там даёт видеокарта и настройки графики в самой игре.

These tweaks reduce background system load, smooth out frame-time, and lower input/network latency. They are **not a substitute** for hardware upgrades and won't guarantee a multiplied FPS boost in GPU-bound scenarios — the GPU and in-game graphics settings matter most there.

---

## Запуск / Running

Положите `Start-WinGameOptimizer.bat` и `WinGameOptimizer.ps1` в одну папку и запустите `.bat` (двойной клик). Он исправит кодировку файла (UTF-8 с BOM) и запустит скрипт; права администратора запросятся автоматически. Не копируйте код через буфер обмена — скачивайте файлы кнопкой Raw/ZIP: без BOM Windows PowerShell 5.1 ломает кириллицу и парсинг.

Put both files in one folder and run the `.bat`. It fixes the file encoding (UTF-8 with BOM) and launches the script, requesting admin rights automatically. Download files via Raw/ZIP rather than copy-pasting.

## Требования / Requirements

- Windows 10 (1903+) или Windows 11, x64.
- PowerShell 5.1+ (встроен в Windows).
- Права администратора.

- Windows 10 (1903+) or Windows 11, x64.
- PowerShell 5.1+ (built into Windows).
- Administrator rights.

## Лицензия / License

© 2026 Klivlin. Все права защищены. Код опубликован для ознакомления; копирование, изменение, перепубликация и распространение без письменного разрешения автора запрещены. Подробности — в файле [LICENSE](LICENSE).

© 2026 Klivlin. All rights reserved. Source is published for viewing only; copying, modification, republishing and redistribution without the author's written permission are prohibited. See [LICENSE](LICENSE).
