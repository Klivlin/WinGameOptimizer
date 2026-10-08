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

- Не отключает антивирус/Защитник Windows (Defender) и брандмауэр.
  Does not disable antivirus/Windows Defender or the firewall.
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

### 2. Вкладка «GPU / Дисплей» / GPU & Display tab
| RU | EN | Эффект |
|---|---|---|
| Hardware-Accelerated GPU Scheduling (HAGS) | same | Планирование GPU на уровне драйвера вместо CPU-диспетчера, снижает задержку рендера на поддерживаемых GPU |
| Отключить Game DVR / Xbox Game Bar overlay | Disable Game DVR / Xbox Game Bar overlay | Убирает фоновую запись/оверлей, разгружает GPU/CPU во время игры |
| Приоритет GPU/CPU для игр (MMCSS "Games") | Game-priority MMCSS profile | Повышает multimedia-приоритет игровых процессов в планировщике Windows |
| Визуальные эффекты "Лучшее быстродействие" (выкл. по умолчанию) | "Best performance" visual effects (off by default) | Отключает анимации Windows, немного освобождает CPU/GPU |

### 3. Вкладка «Сеть» / Network tab
| RU | EN | Эффект |
|---|---|---|
| Отключить Network Throttling Index | Disable Network Throttling Index | Снимает искусственное ограничение пропускной способности мультимедиа-трафика в MMCSS |
| Отключить алгоритм Нагла (TCPNoDelay) | Disable Nagle's algorithm (TCPNoDelay) | Снижает задержку отправки мелких TCP-пакетов — важно для сетевого кода большинства игр |
| Flush DNS + сброс Winsock (выкл. по умолчанию) | Flush DNS + reset Winsock (off by default) | Устраняет повреждённые сетевые настройки/DNS-кэш, может помочь при высоком пинге |

### 4. Вкладка «Система» / System tab
| RU | EN | Эффект |
|---|---|---|
| Остановить фоновые службы (SysMain, WSearch, DiagTrack, dmwappushservice, MapsBroker, lfsvc, RetailDemo, WerSvc, PcaSvc) | Stop background services (same list) | Снижает фоновую нагрузку на CPU/диск от индексации, телеметрии, геолокации и т.д. |
| Отключить фоновые задачи планировщика (телеметрия, CEIP, карты, отзывы) | Disable background scheduled tasks (telemetry, CEIP, maps, feedback) | Убирает периодические фоновые "просыпания" системы |
| Отключить фоновые UWP-приложения | Disable background UWP apps | UWP-приложения из Store не работают в фоне и не тратят ресурсы |
| Отключить энергосбережение сетевой карты | Disable NIC power saving | NIC не уходит в低power-режим, снижает сетевые микро-лаги/джиттер |
| Отключить гибернацию (выкл. по умолчанию) | Disable hibernation (off by default) | Освобождает место на диске (убирает hiberfil.sys) |
| Очистить temp/кэш/корзину | Clean temp/cache/recycle bin | Освобождает место, убирает мусорные файлы, которые может сканировать антивирус/индексатор |

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
| Отключить Spectre/Meltdown mitigations (выкл. по умолчанию, с отдельным подтверждением) | Disable Spectre/Meltdown mitigations (off by default, separate confirmation) | Заметный прирост в CPU-bound сценариях, но снижает защиту процессора от атак по сторонним каналам |

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

## Требования / Requirements

- Windows 10 (1903+) или Windows 11, x64.
- PowerShell 5.1+ (встроен в Windows).
- Права администратора.

- Windows 10 (1903+) or Windows 11, x64.
- PowerShell 5.1+ (built into Windows).
- Administrator rights.

## Лицензия / License

MIT — используйте и изменяйте свободно, на свой риск.
MIT — use and modify freely, at your own risk.
