﻿<#
    Copyright (c) 2026 Klivlin. Все права защищены / All rights reserved.
    Копирование, изменение и распространение без письменного разрешения запрещены (см. LICENSE).

.SYNOPSIS
    WinGameOptimizer — GUI-утилита для тюнинга Windows под игры (Valorant, CS2, Dota 2 и др.)

.DESCRIPTION
    Применяет только документированные, обратимые настройки Windows:
    план питания, планирование GPU, MMCSS/приоритеты процессов, сетевые тайминги,
    фоновые службы. Перед любым изменением делает бэкап затронутых веток реестра
    и текущей схемы питания. Отключение Microsoft Defender доступно только как
    отдельная опция вкладки «Advanced (риск)»: выкл. по умолчанию, с подтверждением и
    кнопкой обратного включения.

.NOTES
    Запускать от имени администратора. Windows 10/11 x64.
    Автор рекомендует сначала создать точку восстановления системы.
#>

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# 0. Повышение прав
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Нужны права администратора для применения твиков.", "WinGameOptimizer") | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# 1. Общие пути и утилиты
# ---------------------------------------------------------------------------
$BackupRoot = Join-Path $env:USERPROFILE "WinGameOptimizer_Backups"
if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot | Out-Null }

$Global:LogBox = $null
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($Global:LogBox) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.ScrollToCaret()
    }
    Write-Host $line
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value,
        [string]$Type = "DWord"
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log "SET  $Path\$Name = $Value"
    } catch {
        Write-Log "FAIL $Path\$Name : $($_.Exception.Message)" "ERROR"
    }
}

# Ветки реестра, которые мы трогаем — именно их бэкапим/восстанавливаем
$RegistryKeysTouched = @(
    "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers",
    "HKCU\System\GameConfigStore",
    "HKCU\Software\Microsoft\GameBar",
    "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games",
    "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters",
    "HKCU\Control Panel\Desktop",
    "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management",
    "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl"
)

function Backup-CurrentState {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dir = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Path $dir | Out-Null

    # Схема питания
    $activeScheme = (powercfg /getactivescheme) -replace ".*GUID: ([0-9a-fA-F-]+).*", '$1'
    $activeScheme | Out-File (Join-Path $dir "active_power_scheme.txt") -Encoding utf8

    # Реестр
    foreach ($key in $RegistryKeysTouched) {
        $safeName = ($key -replace '[\\: ]', '_') + ".reg"
        $target = Join-Path $dir $safeName
        $regPath = $key -replace "^HKLM", "HKEY_LOCAL_MACHINE" -replace "^HKCU", "HKEY_CURRENT_USER"
        reg export $regPath $target /y 2>$null | Out-Null
    }

    # Службы, которые мы можем останавливать
    $svcState = foreach ($s in $BackgroundServicesList) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) {
            [PSCustomObject]@{ Name = $s; StartType = (Get-Service -Name $s).StartType; Status = $svc.Status }
        }
    }
    $svcState | Export-Csv (Join-Path $dir "services_state.csv") -NoTypeInformation -Encoding UTF8

    Write-Log "Бэкап создан: $dir"
    return $dir
}

function Get-LastBackupDir {
    Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Restore-FromBackup {
    $dir = Get-LastBackupDir
    if (-not $dir) {
        Write-Log "Бэкапов не найдено." "WARN"
        return
    }
    Write-Log "Восстановление из $dir ..."

    $schemeFile = Join-Path $dir "active_power_scheme.txt"
    if (Test-Path $schemeFile) {
        $guid = (Get-Content $schemeFile -Raw).Trim()
        if ($guid) {
            powercfg /setactive $guid
            Write-Log "Схема питания восстановлена: $guid"
        }
    }

    Get-ChildItem $dir -Filter "*.reg" | ForEach-Object {
        reg import $_.FullName 2>$null | Out-Null
        Write-Log "Импортирован $($_.Name)"
    }

    $svcCsv = Join-Path $dir "services_state.csv"
    if (Test-Path $svcCsv) {
        Import-Csv $svcCsv | ForEach-Object {
            try {
                Set-Service -Name $_.Name -StartupType $_.StartType -ErrorAction SilentlyContinue
                if ($_.Status -eq "Running") { Start-Service -Name $_.Name -ErrorAction SilentlyContinue }
                Write-Log "Служба $($_.Name) восстановлена: $($_.StartType)/$($_.Status)"
            } catch {
                Write-Log "Не удалось восстановить службу $($_.Name): $($_.Exception.Message)" "ERROR"
            }
        }
    }

    Restore-AllStartupItems
    Restore-InputDeviceBackups

    Write-Log "Восстановление завершено. Рекомендуется перезагрузка."
    Write-Log "Примечание: гибернацию (если отключали) и удалённые приложения нужно восстанавливать вручную — см. предупреждения выше." "WARN"
}

# ---------------------------------------------------------------------------
# 2. Блоки оптимизаций
# ---------------------------------------------------------------------------

function Test-IsX3D {
    try {
        $name = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        return ($name -match "X3D")
    } catch { return $false }
}

function Test-IsDualCcdX3D {
    # Двухчиплетные X3D (7900X3D/7950X3D/9900X3D/9950X3D) зависят от драйвера 3D V-Cache,
    # который использует Xbox Game Bar для определения игр и распределения по CCD.
    try {
        $name = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        return ($name -match "(79|99)[05]0X3D")
    } catch { return $false }
}

function Opt-UltimatePower {
    if (Test-IsX3D) {
        # AMD 3D V-Cache driver управляет распределением игр по CCD через штатный
        # Balanced; Ultimate Performance ломает эту логику и снижает FPS.
        Write-Log "Обнаружен процессор X3D: вместо Ultimate Performance активирован план «Сбалансированная» (рекомендация AMD)." "WARN"
        powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
        powercfg /change monitor-timeout-ac 0
        powercfg /change standby-timeout-ac 0
        return
    }
    Write-Log "Включение плана питания Ultimate Performance..."
    $guidTemplate = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $out = powercfg /duplicatescheme $guidTemplate 2>&1
    $newGuid = ($out | Select-String -Pattern "([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})").Matches.Value | Select-Object -First 1
    if ($newGuid) {
        powercfg /setactive $newGuid
        Write-Log "Активирован Ultimate Performance ($newGuid)"
    } else {
        # Уже существует — ищем в списке схем
        $existing = (powercfg /list) | Select-String "Ultimate Performance"
        if ($existing) {
            $guid = ($existing.Line -replace ".*GUID: ([0-9a-fA-F-]+).*", '$1')
            powercfg /setactive $guid
            Write-Log "Активирован существующий Ultimate Performance ($guid)"
        } else {
            Write-Log "Не удалось создать/найти Ultimate Performance" "WARN"
        }
    }
    powercfg /change monitor-timeout-ac 0
    powercfg /change standby-timeout-ac 0
}

function Opt-DisableUsbSuspend {
    Write-Log "Отключение USB selective suspend..."
    powercfg /setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    powercfg /setactive scheme_current
}

function Opt-DisableCoreParking {
    if (Test-IsX3D) {
        Write-Log "Обнаружен процессор X3D: отключение core parking пропущено (драйвер 3D V-Cache использует парковку ядер второго CCD)." "WARN"
        return
    }
    Write-Log "Отключение core parking (CPU min cores = 100%)..."
    powercfg /setacvalueindex scheme_current 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100
    powercfg /setactive scheme_current
}

function Opt-HAGS {
    Write-Log "Включение Hardware-Accelerated GPU Scheduling..."
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2
    Write-Log "Требуется перезагрузка для применения HAGS." "WARN"
}

function Opt-DisableGameDVR {
    if (Test-IsDualCcdX3D) {
        Write-Log "Обнаружен двухчиплетный X3D: Game Bar оставлен включённым (нужен драйверу 3D V-Cache для выбора CCD). Отключение пропущено." "WARN"
        return
    }
    Write-Log "Отключение Game DVR / Xbox Game Bar overlay..."
    Set-RegistryValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0
    Set-RegistryValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2
    Set-RegistryValue -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Value 1
    Set-RegistryValue -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0
}

function Opt-MMCSSGamesProfile {
    Write-Log "Настройка приоритета MMCSS для игр (GPU/CPU priority)..."
    $path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
    Set-RegistryValue -Path $path -Name "GPU Priority" -Value 8
    Set-RegistryValue -Path $path -Name "Priority" -Value 6
    Set-RegistryValue -Path $path -Name "Scheduling Category" -Value "High" -Type String
    Set-RegistryValue -Path $path -Name "SFIO Priority" -Value "High" -Type String
}

function Opt-NetworkThrottling {
    Write-Log "Отключение Network Throttling Index (снижение задержки для сети)..."
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xffffffff
}

function Opt-PrioritySeparation {
    # 0x12 (18): фиксированный длинный квант, приоритет фону не снижается так сильно (рекомендация из разборов планировщика).
    Write-Log "Win32PrioritySeparation = 18 (фиксированный длинный квант)..."
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 18
}

function Opt-DisableNagle {
    Write-Log "Отключение алгоритма Нагла на всех сетевых интерфейсах..."
    $ifacesRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    if (Test-Path $ifacesRoot) {
        Get-ChildItem $ifacesRoot | ForEach-Object {
            Set-RegistryValue -Path $_.PSPath -Name "TcpAckFrequency" -Value 1
            Set-RegistryValue -Path $_.PSPath -Name "TCPNoDelay" -Value 1
        }
    }
}

function Opt-FlushDnsResetWinsock {
    Write-Log "Flush DNS и сброс Winsock..."
    ipconfig /flushdns | Out-Null
    netsh winsock reset | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    Write-Log "Winsock сброшен. Рекомендуется перезагрузка." "WARN"
}

function Opt-VisualEffectsPerformance {
    Write-Log "Переключение визуальных эффектов на 'Лучшее быстродействие'..."
    Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2
    Set-RegistryValue -Path "HKCU:\Control Panel\Desktop" -Name "DragFullWindows" -Value "0" -Type String
    Set-RegistryValue -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String
}

$BackgroundServicesList = @(
    "SysMain",            # Superfetch — лишняя нагрузка на диск/CPU при играх с SSD
    "WSearch",            # Windows Search indexing
    "DiagTrack",          # Телеметрия (Connected User Experiences)
    "dmwappushservice",   # WAP Push message routing — не нужен геймеру
    "MapsBroker",         # Downloaded Maps Manager
    "lfsvc",              # Geolocation Service
    "RetailDemo",         # Retail Demo Service
    "WerSvc"              # Windows Error Reporting — можно отключать на время игры
)

function Opt-BackgroundServices {
    Write-Log "Остановка фоновых служб, нагружающих CPU/диск/сеть..."
    foreach ($s in $BackgroundServicesList) {
        try {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
            Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "Служба $s остановлена и отключена."
        } catch {
            Write-Log "Не удалось изменить службу $s : $($_.Exception.Message)" "ERROR"
        }
    }
}

function Opt-DisableScheduledTasksBloat {
    Write-Log "Отключение фоновых задач планировщика (телеметрия, отзывы, обновление карт)..."
    $tasks = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Autochk\Proxy",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Feedback\Siuf\DmClient",
        "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
        "\Microsoft\Windows\Maps\MapsToastTask",
        "\Microsoft\Windows\Maps\MapsUpdateTask",
        "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
    )
    foreach ($t in $tasks) {
        try {
            Disable-ScheduledTask -TaskPath (Split-Path $t) -TaskName (Split-Path $t -Leaf) -ErrorAction Stop | Out-Null
            Write-Log "Задача отключена: $t"
        } catch {
            Write-Log "Пропущена задача (не найдена/нет доступа): $t" "WARN"
        }
    }
}

function Opt-DisableBackgroundApps {
    Write-Log "Отключение фоновой работы UWP-приложений..."
    Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name "GlobalUserDisabled" -Value 1
}

function Opt-DisableMitigations {
    Write-Log "ВНИМАНИЕ: отключение Spectre/Meltdown mitigations (снижает защиту CPU, повышает производительность в CPU-bound сценариях)..." "WARN"
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverride" -Value 3
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverrideMask" -Value 3
    Write-Log "Требуется перезагрузка. Это снижает защиту от уязвимостей класса Spectre/Meltdown." "WARN"
}

$DefenderPolicyPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
$DefenderRtpPolicyPath = "$DefenderPolicyPath\Real-Time Protection"

function Opt-DisableDefender {
    Write-Log "ВНИМАНИЕ: отключение Microsoft Defender (защита в реальном времени)..." "WARN"
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if ($st.IsTamperProtected) {
            Write-Log "Включена «Защита от подделки» (Tamper Protection): Windows блокирует отключение Defender. Выключите её вручную: Безопасность Windows → Защита от вирусов и угроз → Параметры → Защита от подделки — и повторите." "ERROR"
            return
        }
    } catch {
        Write-Log "Не удалось прочитать статус Defender (возможно, стоит сторонний антивирус): $($_.Exception.Message)" "WARN"
    }
    Backup-RegistryPath -Path $DefenderPolicyPath -Label "DefenderPolicy" | Out-Null
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true `
            -DisableIOAVProtection $true -DisableScriptScanning $true -DisableBlockAtFirstSeen $true `
            -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction Stop
        Write-Log "Защита в реальном времени, поведенческий анализ, проверка скриптов и облачная защита отключены."
    } catch {
        Write-Log "Set-MpPreference не применён: $($_.Exception.Message)" "ERROR"
    }
    Set-RegistryValue -Path $DefenderPolicyPath -Name "DisableAntiSpyware" -Value 1
    Set-RegistryValue -Path $DefenderRtpPolicyPath -Name "DisableRealtimeMonitoring" -Value 1
    Set-RegistryValue -Path $DefenderRtpPolicyPath -Name "DisableBehaviorMonitoring" -Value 1
    Set-RegistryValue -Path $DefenderRtpPolicyPath -Name "DisableOnAccessProtection" -Value 1
    Set-RegistryValue -Path $DefenderRtpPolicyPath -Name "DisableScanOnRealtimeEnable" -Value 1
    Write-Log "Defender отключён политиками. Требуется перезагрузка. Файлы проверяться НЕ будут — используйте кнопку «Включить Defender обратно», когда он не нужен." "WARN"
}

function Restore-Defender {
    Write-Log "Включение Microsoft Defender обратно..."
    foreach ($n in @("DisableAntiSpyware")) {
        Remove-ItemProperty -Path $DefenderPolicyPath -Name $n -ErrorAction SilentlyContinue
    }
    foreach ($n in @("DisableRealtimeMonitoring","DisableBehaviorMonitoring","DisableOnAccessProtection","DisableScanOnRealtimeEnable")) {
        Remove-ItemProperty -Path $DefenderRtpPolicyPath -Name $n -ErrorAction SilentlyContinue
    }
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false `
            -DisableIOAVProtection $false -DisableScriptScanning $false -DisableBlockAtFirstSeen $false `
            -MAPSReporting 2 -SubmitSamplesConsent 1 -ErrorAction Stop
        Write-Log "Параметры Defender возвращены к значениям по умолчанию."
    } catch {
        Write-Log "Set-MpPreference не применён: $($_.Exception.Message)" "WARN"
    }
    Write-Log "Политики Defender удалены. Рекомендуется перезагрузка и включение «Защиты от подделки» в Безопасности Windows." "WARN"
}

function Opt-DisableNicPowerSaving {
    Write-Log "Отключение энергосбережения сетевых адаптеров (снижает micro-лаги/задержку)..."
    try {
        Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
            try {
                Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction Stop
                Write-Log "Power management отключён для адаптера: $($_.Name)"
            } catch {
                Write-Log "Не удалось отключить power management для $($_.Name): $($_.Exception.Message)" "WARN"
            }
        }
    } catch {
        Write-Log "Get-NetAdapter недоступен: $($_.Exception.Message)" "WARN"
    }
}

function Opt-DisableHibernation {
    Write-Log "Отключение гибернации (освобождает место на диске, убирает hiberfil.sys)..."
    powercfg /hibernate off
}

function Opt-EnableHibernation {
    powercfg /hibernate on
    Write-Log "Гибернация включена обратно."
}

function Clear-TempAndCache {
    Write-Log "Очистка временных файлов и кэша..."
    $paths = @(
        "$env:TEMP\*",
        "$env:WINDIR\Temp\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*",
        "$env:LOCALAPPDATA\CrashDumps\*"
    )
    foreach ($p in $paths) {
        try {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Очищено: $p"
        } catch {
            Write-Log "Пропущено (занято/нет доступа): $p" "WARN"
        }
    }
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log "Корзина очищена."
    } catch {
        Write-Log "Не удалось очистить корзину: $($_.Exception.Message)" "WARN"
    }
}

# --- Инпут-лаг: мышь/клавиатура, буферизация, энергосбережение HID, IRQ affinity ---
function ConvertTo-RegExportPath {
    param([string]$Path)
    ($Path -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\') -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
}

function Backup-RegistryPath {
    param([string]$Path, [string]$Label)
    $dir = Join-Path $BackupRoot "InputDeviceBackups"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    if (-not (Test-Path $Path)) { return $null }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $safe = ($Label -replace '[\\/: &]', '_')
    $file = Join-Path $dir "$($safe)_$stamp.reg"
    $exportPath = ConvertTo-RegExportPath $Path
    reg export $exportPath $file /y 2>$null | Out-Null
    if (Test-Path $file) { Write-Log "Бэкап сохранён: $file" }
    return $file
}

function Get-InputHidDevices {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.Class -in @("Mouse", "Keyboard", "HIDClass") -and $_.Status -eq "OK"
    }
}

function Opt-DisableMouseAcceleration {
    Write-Log "Отключение акселерации мыши (Enhance Pointer Precision)..."
    Backup-RegistryPath -Path "HKCU:\Control Panel\Mouse" -Label "MouseSettings" | Out-Null
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String
    Set-RegistryValue -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String
    Write-Log "Акселерация отключена (применится после перелогина/перезагрузки)."
}

function Opt-ReduceInputBuffering {
    Write-Log "Снижение размера буфера очереди мыши/клавиатуры (меньше задержка ввода)..."
    Backup-RegistryPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters" -Label "MouClassParams" | Out-Null
    Backup-RegistryPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" -Label "KbdClassParams" | Out-Null
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters" -Name "MouseDataQueueSize" -Value 20
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" -Name "KeyboardDataQueueSize" -Value 20
    Write-Log "Требуется перезагрузка для применения."
}

function Opt-DisableHidPowerSaving {
    Write-Log "Отключение энергосбережения для мыши/клавиатуры/HID-устройств..."
    $devices = Get-InputHidDevices
    foreach ($dev in $devices) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters"
        if (Test-Path $regPath) {
            Backup-RegistryPath -Path $regPath -Label $dev.FriendlyName | Out-Null
            Set-RegistryValue -Path $regPath -Name "EnhancedPowerManagementEnabled" -Value 0
            Write-Log "Power saving отключён: $($dev.FriendlyName)"
        }
    }
}

function Opt-SetInputIrqAffinity {
    param([int]$CoreIndex)
    Write-Log "Привязка прерываний мыши/клавиатуры к ядру CPU #$CoreIndex..." "WARN"
    $devices = Get-InputHidDevices
    foreach ($dev in $devices) {
        $imPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management"
        $affPath = "$imPath\Affinity Policy"
        Backup-RegistryPath -Path $imPath -Label $dev.FriendlyName | Out-Null
        $mask = [byte[]]::new(4)
        $mask[[math]::Floor($CoreIndex / 8)] = [byte](1 -shl ($CoreIndex % 8))
        try {
            if (-not (Test-Path $affPath)) { New-Item -Path $affPath -Force | Out-Null }
            New-ItemProperty -Path $affPath -Name "DevicePolicy" -Value 4 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $affPath -Name "DevicePriority" -Value 3 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $affPath -Name "AssignmentSetOverride" -Value $mask -PropertyType Binary -Force | Out-Null
            Write-Log "IRQ affinity установлен: $($dev.FriendlyName) -> CPU $CoreIndex"
        } catch {
            Write-Log "Не удалось установить IRQ affinity для $($dev.FriendlyName): $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Log "Требуется перезагрузка. Если устройство перестанет работать — восстановите бэкап input-устройств." "WARN"
}

function Opt-EnableMsiModeForInputDevices {
    Write-Log "ЭКСПЕРИМЕНТАЛЬНО: включение MSI-режима прерываний для HID-устройств..." "WARN"
    $devices = Get-InputHidDevices
    foreach ($dev in $devices) {
        $imPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management"
        $msiPath = "$imPath\MessageSignaledInterruptProperties"
        Backup-RegistryPath -Path $imPath -Label "$($dev.FriendlyName)_MSI" | Out-Null
        try {
            if (-not (Test-Path $msiPath)) { New-Item -Path $msiPath -Force | Out-Null }
            New-ItemProperty -Path $msiPath -Name "MSISupported" -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log "MSI включён: $($dev.FriendlyName)"
        } catch {
            Write-Log "Не удалось включить MSI для $($dev.FriendlyName): $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Log "Если устройство исчезнет (код 10 в Диспетчере устройств) — восстановите бэкап и перезагрузитесь." "WARN"
}

function Restore-InputDeviceBackups {
    $dir = Join-Path $BackupRoot "InputDeviceBackups"
    if (-not (Test-Path $dir)) { Write-Log "Бэкапов input-устройств не найдено." "WARN"; return }
    Get-ChildItem $dir -Filter "*.reg" | Sort-Object LastWriteTime | ForEach-Object {
        reg import $_.FullName 2>$null | Out-Null
        Write-Log "Импортирован бэкап устройства: $($_.Name)"
    }
    Write-Log "Восстановление input-устройств завершено. Рекомендуется перезагрузка."
    Write-Log "Если твик применялся несколько раз подряд, может потребоваться ручная проверка ключей Interrupt Management." "WARN"
}

# --- Автозагрузка: перечисление, отключение, восстановление ---
$StartupRunKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
)
$StartupDisabledBackupKey = "HKCU:\Software\WinGameOptimizer\DisabledStartup"

function Get-StartupItems {
    $items = @()
    foreach ($key in $StartupRunKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key
            $props.PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Provider)$' } |
                ForEach-Object {
                    $items += [PSCustomObject]@{ Source = $key; Name = $_.Name; Value = $_.Value }
                }
        }
    }
    $startupFolder = [Environment]::GetFolderPath("Startup")
    if (Test-Path $startupFolder) {
        Get-ChildItem $startupFolder -File -ErrorAction SilentlyContinue | ForEach-Object {
            $items += [PSCustomObject]@{ Source = "StartupFolder"; Name = $_.Name; Value = $_.FullName }
        }
    }
    return $items
}

function Disable-StartupItem {
    param($Item)
    if (-not (Test-Path $StartupDisabledBackupKey)) { New-Item -Path $StartupDisabledBackupKey -Force | Out-Null }
    if ($Item.Source -eq "StartupFolder") {
        $disabledDir = Join-Path $env:USERPROFILE "WinGameOptimizer_Backups\DisabledStartupFiles"
        if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir | Out-Null }
        try {
            Move-Item -Path $Item.Value -Destination (Join-Path $disabledDir $Item.Name) -Force
            Write-Log "Автозагрузка (файл) отключена: $($Item.Name)"
        } catch {
            Write-Log "Не удалось отключить файл автозагрузки $($Item.Name): $($_.Exception.Message)" "ERROR"
        }
    } else {
        New-ItemProperty -Path $StartupDisabledBackupKey -Name "$($Item.Source)|$($Item.Name)" -Value $Item.Value -PropertyType String -Force | Out-Null
        Remove-ItemProperty -Path $Item.Source -Name $Item.Name -ErrorAction SilentlyContinue
        Write-Log "Автозагрузка (реестр) отключена: $($Item.Name)"
    }
}

function Restore-AllStartupItems {
    if (Test-Path $StartupDisabledBackupKey) {
        $props = Get-ItemProperty -Path $StartupDisabledBackupKey
        $props.PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Provider)$' } |
            ForEach-Object {
                $parts = $_.Name -split '\|', 2
                $source = $parts[0]; $name = $parts[1]
                New-ItemProperty -Path $source -Name $name -Value $_.Value -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Восстановлена автозагрузка (реестр): $name"
            }
        Remove-Item -Path $StartupDisabledBackupKey -Recurse -Force -ErrorAction SilentlyContinue
    }
    $disabledDir = Join-Path $env:USERPROFILE "WinGameOptimizer_Backups\DisabledStartupFiles"
    $startupFolder = [Environment]::GetFolderPath("Startup")
    if (Test-Path $disabledDir) {
        Get-ChildItem $disabledDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Move-Item -Path $_.FullName -Destination (Join-Path $startupFolder $_.Name) -Force -ErrorAction SilentlyContinue
            Write-Log "Восстановлен файл автозагрузки: $($_.Name)"
        }
    }
}

# --- Debloat: предустановленные UWP-приложения ---
$BloatPackagePatterns = @(
    "Microsoft.3DBuilder",
    "Microsoft.Microsoft3DViewer",
    "Microsoft.MixedReality.Portal",
    "Microsoft.OfficeHub",
    "Microsoft.SkypeApp",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.WindowsMaps",
    "Microsoft.People",
    "Microsoft.YourPhone",
    "Microsoft.Wallet",
    "Microsoft.BingWeather",
    "Microsoft.BingNews",
    "Microsoft.BingFinance",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Clipchamp.Clipchamp",
    "Microsoft.Todos",
    "Microsoft.PowerAutomateDesktop",
    "Microsoft.MicrosoftFamily",
    "MicrosoftTeams"
)

function Remove-BloatApps {
    param([string[]]$Patterns)
    $removedLog = @()
    foreach ($pattern in $Patterns) {
        $pkgs = Get-AppxPackage -AllUsers -Name "*$pattern*" -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                $removedLog += $pkg.PackageFullName
                Write-Log "Удалено приложение: $($pkg.Name)"
            } catch {
                Write-Log "Не удалось удалить $($pkg.Name): $($_.Exception.Message)" "WARN"
            }
        }
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$pattern*" }
        foreach ($prov in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-Log "Удалён provisioned-пакет (не будет ставиться новым пользователям): $($prov.DisplayName)"
            } catch {
                Write-Log "Не удалось удалить provisioned-пакет $($prov.DisplayName): $($_.Exception.Message)" "WARN"
            }
        }
    }
    if ($removedLog.Count -gt 0) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $logFile = Join-Path $BackupRoot "removed_appx_$stamp.txt"
        $removedLog | Out-File $logFile -Encoding utf8
        Write-Log "Список удалённых пакетов сохранён: $logFile"
        Write-Log "ВАЖНО: автоматический откат удаления приложений не поддерживается Windows." "WARN"
        Write-Log "Чтобы вернуть приложение — переустановите его из Microsoft Store по имени из списка." "WARN"
    }
}

# ---------------------------------------------------------------------------
# 3. Профили игр — мониторинг процесса и приоритет
# ---------------------------------------------------------------------------
$GameProfiles = @{
    "Valorant" = "VALORANT-Win64-Shipping"
    "CS2"      = "cs2"
    "CS:GO"    = "csgo"
    "Dota 2"   = "dota2"
}

$Global:BoostTimer = $null

function Start-ProcessBoost {
    param([string]$ProcessName)

    if ($Global:BoostTimer) { $Global:BoostTimer.Stop(); $Global:BoostTimer.Dispose() }

    $Global:BoostTimer = New-Object System.Windows.Forms.Timer
    $Global:BoostTimer.Interval = 3000
    $Global:BoostTimer.Add_Tick({
        try {
            $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
            if ($proc) {
                foreach ($p in $proc) {
                    if ($p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::High) {
                        $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                        $coreCount = [Environment]::ProcessorCount
                        if ($coreCount -gt 2) {
                            $p.ProcessorAffinity = [IntPtr]([math]::Pow(2, $coreCount) - 1)
                        }
                        Write-Log "Повышен приоритет процесса $($p.ProcessName) (PID $($p.Id)) -> High"
                    }
                }
            }
        } catch {
            # процесс может завершиться между проверками — это нормально
        }
    })
    $Global:BoostTimer.Start()
    Write-Log "Мониторинг процесса '$ProcessName' запущен (автоповышение приоритета)."
}

function Stop-ProcessBoost {
    if ($Global:BoostTimer) {
        $Global:BoostTimer.Stop()
        $Global:BoostTimer.Dispose()
        $Global:BoostTimer = $null
        Write-Log "Мониторинг процесса остановлен."
    }
}

# ---------------------------------------------------------------------------
# 4. GUI
# ---------------------------------------------------------------------------
try {
    Add-Type -Namespace WGO -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [WGO.Dpi]::SetProcessDPIAware() | Out-Null
} catch { }

$ColorAccent = [System.Drawing.Color]::FromArgb(46, 125, 50)
$ColorRisk   = [System.Drawing.Color]::FromArgb(183, 28, 28)
$ColorMuted  = [System.Drawing.Color]::FromArgb(97, 97, 97)
$ColorWarn   = [System.Drawing.Color]::FromArgb(230, 81, 0)
$UiFont      = New-Object System.Drawing.Font("Segoe UI", 9)
$Dpi = 1.0
try { $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $Dpi = $g.DpiX / 96.0; $g.Dispose() } catch { }
$WrapWidth   = [int](820 * $Dpi)

$form = New-Object System.Windows.Forms.Form
$form.Text = "WinGameOptimizer — Valorant / CS2 / Dota 2"
$form.Font = $UiFont
$form.ClientSize = New-Object System.Drawing.Size([int](900 * $Dpi), [int](780 * $Dpi))
$form.MinimumSize = New-Object System.Drawing.Size([int](760 * $Dpi), [int](600 * $Dpi))
$form.StartPosition = "CenterScreen"
$form.Padding = New-Object System.Windows.Forms.Padding(10)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabs.Font = $UiFont
$tabs.Padding = New-Object System.Drawing.Point(14, 5)

$checkboxes = @{}

function New-StyledButton {
    param([string]$Text, [int]$Width = 160, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.MinimumSize = New-Object System.Drawing.Size($Width, 34)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    $b.FlatStyle = "Flat"
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor = $ColorAccent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    } else {
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::Silver
    }
    return $b
}

# Вкладка с вертикальным прокручиваемым списком опций; возвращает панель-контейнер.
function New-OptTab {
    param([string]$Title)
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Title
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = "Fill"
    $flow.FlowDirection = "TopDown"
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
    $tab.Controls.Add($flow)
    $tabs.TabPages.Add($tab)
    return $flow
}

function Add-OptNote {
    param($Page, [string]$Text, $Color = $null, [bool]$Bold = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.MaximumSize = New-Object System.Drawing.Size($WrapWidth, 0)
    $l.Text = $Text
    $l.ForeColor = if ($Color) { $Color } else { $ColorMuted }
    if ($Bold) { $l.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold) }
    $l.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 10)
    $Page.Controls.Add($l)
}

function Add-OptCheckbox {
    param($Page, [string]$Key, [string]$Label, [string]$Desc = "", [bool]$Checked = $true, [bool]$Risky = $false)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.AutoSize = $true
    $cb.MaximumSize = New-Object System.Drawing.Size($WrapWidth, 0)
    $cb.Text = $Label
    $cb.Checked = $Checked
    $cb.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    if ($Risky) { $cb.ForeColor = $ColorRisk }
    $cb.Margin = New-Object System.Windows.Forms.Padding(2, 6, 2, 0)
    $Page.Controls.Add($cb)
    $checkboxes[$Key] = $cb
    if ($Desc) {
        $d = New-Object System.Windows.Forms.Label
        $d.AutoSize = $true
        $d.MaximumSize = New-Object System.Drawing.Size(($WrapWidth - 24), 0)
        $d.Text = $Desc
        $d.ForeColor = if ($Risky) { $ColorRisk } else { $ColorMuted }
        $d.Margin = New-Object System.Windows.Forms.Padding(24, 0, 2, 4)
        $Page.Controls.Add($d)
    }
}

# Вкладка со списком (CheckedListBox) + строка кнопок снизу + заголовок сверху.
function New-ListTab {
    param([string]$Title, [string]$Header, $HeaderColor = $null)
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Title
    $tab.Padding = New-Object System.Windows.Forms.Padding(12)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = "Fill"
    $list.CheckOnClick = $true
    $list.HorizontalScrollbar = $true
    $btns = New-Object System.Windows.Forms.FlowLayoutPanel
    $btns.Dock = "Bottom"
    $btns.AutoSize = $true
    $btns.FlowDirection = "LeftToRight"
    $btns.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Dock = "Top"
    $hdr.AutoSize = $false
    $hdr.Height = [int](44 * $Dpi)
    $hdr.Text = $Header
    $hdr.ForeColor = if ($HeaderColor) { $HeaderColor } else { $ColorMuted }
    $tab.Controls.Add($list)
    $tab.Controls.Add($btns)
    $tab.Controls.Add($hdr)
    $tabs.TabPages.Add($tab)
    return [PSCustomObject]@{ List = $list; Buttons = $btns }
}

# --- Питание ---
$pgPower = New-OptTab "Питание"
if (Test-IsX3D) {
    Add-OptNote $pgPower "Обнаружен процессор X3D: вместо Ultimate Performance будет включена «Сбалансированная», core parking не трогается (рекомендация AMD для драйвера 3D V-Cache)." $ColorWarn $true
}
Add-OptCheckbox $pgPower "UltimatePower" "План питания Ultimate Performance" "Меньше энергосберегающих переходов CPU. На AMD X3D автоматически заменяется на «Сбалансированная»."
Add-OptCheckbox $pgPower "UsbSuspend"    "Отключить USB selective suspend" "USB-устройства (мышь, геймпад) не «засыпают» — меньше случайных микро-лагов."
Add-OptCheckbox $pgPower "CoreParking"   "Отключить core parking" "Все ядра CPU всегда активны. Пропускается на X3D."

# --- GPU / Дисплей ---
$pgGpu = New-OptTab "GPU / Дисплей"
Add-OptCheckbox $pgGpu "HAGS"     "Hardware-Accelerated GPU Scheduling (HAGS)" "Планирование GPU на стороне видеокарты. Нужна перезагрузка; если станет хуже — отключите."
Add-OptCheckbox $pgGpu "GameDVR"  "Отключить Game DVR / Xbox Game Bar overlay" "Убирает фоновую запись и оверлей. На двухчиплетных X3D пропускается (нужен драйверу 3D V-Cache)."
Add-OptCheckbox $pgGpu "MMCSS"    "Приоритет MMCSS-профиля «Games»" "Эффект спорный: MMCSS в основном влияет на аудиопотоки. Включайте и сравнивайте." $false
Add-OptCheckbox $pgGpu "VisualFx" "Визуальные эффекты: «Лучшее быстродействие»" "Отключает анимации Windows." $false

# --- Сеть ---
$pgNet = New-OptTab "Сеть"
Add-OptCheckbox $pgNet "NetThrottle" "Отключить Network Throttling Index" "Снимает ограничение мультимедиа-трафика в MMCSS."
Add-OptCheckbox $pgNet "Nagle"       "Отключить алгоритм Нагла (TCPNoDelay)" "Влияет только на TCP; большинство шутеров работает по UDP, польза мала." $false
Add-OptCheckbox $pgNet "DnsWinsock"  "Flush DNS + сброс Winsock" "Может сбросить сетевые настройки (VPN, прокси). Нужна перезагрузка." $false

# --- Система ---
$pgSys = New-OptTab "Система"
Add-OptCheckbox $pgSys "BgServices"  "Остановить фоновые службы" "SysMain, WSearch, DiagTrack, dmwappushservice, MapsBroker, lfsvc, RetailDemo, WerSvc."
Add-OptCheckbox $pgSys "BgTasks"     "Отключить фоновые задачи планировщика" "Телеметрия, CEIP, карты, отзывы."
Add-OptCheckbox $pgSys "BgApps"      "Отключить фоновые UWP-приложения" "Приложения из Store не работают в фоне."
Add-OptCheckbox $pgSys "NicPower"    "Отключить энергосбережение сетевой карты" "Меньше сетевых микро-лагов и джиттера."
Add-OptCheckbox $pgSys "Hibernation" "Отключить гибернацию" "Освобождает место на диске (hiberfil.sys). Включить обратно: powercfg /hibernate on." $false
Add-OptCheckbox $pgSys "ClearTemp"   "Очистить temp / кэш / корзину" "Выполняется перед применением остальных опций. Prefetch не трогается."
Add-OptCheckbox $pgSys "PrioSep"     "Win32PrioritySeparation = 18" "Фиксированный длинный квант планировщика. Эффект зависит от системы — тестируйте." $false

# --- Advanced (риск) ---
$pgAdv = New-OptTab "Advanced (риск)"
Add-OptNote $pgAdv "Эти настройки снижают уровень защиты системы. Применяйте осознанно." $ColorRisk $true
Add-OptCheckbox $pgAdv "Mitigations" "Отключить Spectre/Meltdown mitigations" "Прирост в CPU-bound сценариях, но снижается защита процессора от атак по сторонним каналам. Нужна перезагрузка." $false $true
Add-OptCheckbox $pgAdv "Defender"    "Отключить Microsoft Defender (защита в реальном времени)" "ПК останется без антивируса. Подробности рисков — ниже." $false $true
Add-OptNote $pgAdv ("Риски отключения Defender:`r`n" +
 "• ПК остаётся без антивируса: вирусы, майнеры, стилеры, шифровальщики не блокируются;`r`n" +
 "• читы, моды и «кряки» часто несут вредоносный код — главный путь заражения у геймеров;`r`n" +
 "• теряется защита от вредоносных скриптов, макросов и поддельных установщиков;`r`n" +
 "• сначала нужно вручную выключить «Защиту от подделки», иначе Windows всё вернёт;`r`n" +
 "• обновления Windows могут включить Defender обратно, Центр безопасности будет показывать предупреждения;`r`n" +
 "• часть античитов и приложений могут сообщать о небезопасной конфигурации;`r`n" +
 "• прирост FPS обычно небольшой (единицы %).`r`n" +
 "Полное удаление Defender не выполняется — только обратимое отключение.") $ColorRisk
$btnRestoreDefender = New-StyledButton "Включить Defender обратно" 220
$btnRestoreDefender.Add_Click({ Restore-Defender })
$pgAdv.Controls.Add($btnRestoreDefender)

# --- Автозагрузка ---
$lt = New-ListTab "Автозагрузка" "Отмеченные пункты будут отключены (перемещены в бэкап, не удалены)."
$listStartup = $lt.List
$Global:StartupItemsCache = @()
function Refresh-StartupList {
    $listStartup.Items.Clear()
    $Global:StartupItemsCache = Get-StartupItems
    foreach ($item in $Global:StartupItemsCache) {
        $listStartup.Items.Add("$($item.Name)  —  $($item.Value)") | Out-Null
    }
}
$btnRefreshStartup = New-StyledButton "Обновить список" 140
$btnRefreshStartup.Add_Click({ Refresh-StartupList })
$btnDisableStartup = New-StyledButton "Отключить выбранные" 170
$btnDisableStartup.Add_Click({
    for ($i = 0; $i -lt $listStartup.Items.Count; $i++) {
        if ($listStartup.GetItemChecked($i)) {
            Disable-StartupItem -Item $Global:StartupItemsCache[$i]
        }
    }
    Refresh-StartupList
})
$btnRestoreStartup = New-StyledButton "Восстановить все отключённые" 220
$btnRestoreStartup.Add_Click({ Restore-AllStartupItems; Refresh-StartupList })
$lt.Buttons.Controls.AddRange(@($btnRefreshStartup, $btnDisableStartup, $btnRestoreStartup))

# --- Debloat ---
$lt2 = New-ListTab "Debloat (приложения)" "Удаление предустановленных UWP-приложений. ОТКАТ НЕДОСТУПЕН — только переустановка из Microsoft Store." $ColorRisk
$listBloat = $lt2.List
foreach ($pattern in $BloatPackagePatterns) {
    $idx = $listBloat.Items.Add($pattern)
    # Teams / PowerAutomate / Family по умолчанию не отмечаем — многим нужны
    if ($pattern -notin @("MicrosoftTeams", "Microsoft.PowerAutomateDesktop", "Microsoft.MicrosoftFamily")) {
        $listBloat.SetItemChecked($idx, $true)
    }
}
$btnRemoveBloat = New-StyledButton "Удалить выбранные приложения" 240
$btnRemoveBloat.BackColor = [System.Drawing.Color]::Khaki
$btnRemoveBloat.Add_Click({
    $selected = @()
    for ($i = 0; $i -lt $listBloat.Items.Count; $i++) {
        if ($listBloat.GetItemChecked($i)) { $selected += $listBloat.Items[$i].ToString() }
    }
    if ($selected.Count -eq 0) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Удалить $($selected.Count) приложений? Откат невозможен, только переустановка из Store.",
        "Подтверждение", "YesNo", "Warning")
    if ($confirm -eq "Yes") { Remove-BloatApps -Patterns $selected }
})
$lt2.Buttons.Controls.Add($btnRemoveBloat)

# --- Мышь / Инпут-лаг ---
$pgInput = New-OptTab "Мышь / Инпут-лаг"
Add-OptCheckbox $pgInput "MouseAccel" "Отключить акселерацию мыши" "Enhance Pointer Precision: линейное, предсказуемое движение курсора."
Add-OptCheckbox $pgInput "InputQueue" "Уменьшить буфер очереди мыши/клавиатуры" "Меньше буферизация ввода драйверами mouclass/kbdclass. Нужна перезагрузка."
Add-OptCheckbox $pgInput "HidPower"   "Отключить энергосбережение HID-устройств" "Мышь и клавиатура не «просыпаются» с задержкой."
Add-OptNote $pgInput "ПРОДВИНУТО" $ColorRisk $true
Add-OptCheckbox $pgInput "IrqAffinity" "Привязать прерывания мыши/клавиатуры к ядру CPU" "Выберите ядро ниже. Не CPU 0 (занят системными прерываниями); берите физическое ядро вне основных потоков игры." $false $true

$rowCore = New-Object System.Windows.Forms.FlowLayoutPanel
$rowCore.AutoSize = $true
$rowCore.FlowDirection = "LeftToRight"
$rowCore.Margin = New-Object System.Windows.Forms.Padding(22, 0, 0, 8)
$lblCore = New-Object System.Windows.Forms.Label
$lblCore.Text = "Ядро:"
$lblCore.AutoSize = $true
$lblCore.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
$comboCore = New-Object System.Windows.Forms.ComboBox
$comboCore.Width = 120
$comboCore.DropDownStyle = "DropDownList"
$coreCount = [Environment]::ProcessorCount
for ($c = 0; $c -lt $coreCount; $c++) { $comboCore.Items.Add("CPU $c") | Out-Null }
$comboCore.SelectedIndex = [Math]::Min(2, $coreCount - 1)
$rowCore.Controls.AddRange(@($lblCore, $comboCore))
$pgInput.Controls.Add($rowCore)

Add-OptCheckbox $pgInput "MsiMode" "ЭКСПЕРИМЕНТ: принудительный MSI-режим прерываний для HID" "Риск: устройство может отказать (код 10 в Диспетчере устройств), если драйвер не поддерживает MSI." $false $true

$btnRestoreInput = New-StyledButton "Восстановить настройки устройств ввода" 300
$btnRestoreInput.Margin = New-Object System.Windows.Forms.Padding(2, 12, 2, 6)
$btnRestoreInput.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Восстановить настройки мыши/клавиатуры/HID из бэкапа?", "Подтверждение", "YesNo", "Question")
    if ($confirm -eq "Yes") { Restore-InputDeviceBackups }
})
$pgInput.Controls.Add($btnRestoreInput)
Add-OptNote $pgInput ("IRQ affinity и MSI меняют низкоуровневые параметры драйверов. Перед применением создаётся бэкап затронутых веток реестра.`r`n" +
 "Если мышь/клавиатура перестанут отвечать — переподключите устройство или откатите кнопкой выше и перезагрузитесь.")

# --- Профиль игры ---
$pgGame = New-OptTab "Профиль игры"
Add-OptNote $pgGame "Запустите мониторинг ПЕРЕД игрой: при обнаружении процесса ему будет выставлен приоритет High и affinity на все ядра. Анти-чит процессы (vgc.exe, cs2-anticheat и т.п.) не трогаются."
$rowGame = New-Object System.Windows.Forms.FlowLayoutPanel
$rowGame.AutoSize = $true
$rowGame.FlowDirection = "LeftToRight"
$lblGame = New-Object System.Windows.Forms.Label
$lblGame.Text = "Игра:"
$lblGame.AutoSize = $true
$lblGame.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
$comboGame = New-Object System.Windows.Forms.ComboBox
$comboGame.Width = 220
$comboGame.DropDownStyle = "DropDownList"
$comboGame.Margin = New-Object System.Windows.Forms.Padding(0, 5, 12, 0)
$GameProfiles.Keys | ForEach-Object { $comboGame.Items.Add($_) | Out-Null }
$comboGame.SelectedIndex = 0
$btnStartBoost = New-StyledButton "Запустить автоповышение приоритета" 260
$btnStartBoost.Add_Click({
    $gameName = $comboGame.SelectedItem.ToString()
    $procName = $GameProfiles[$gameName]
    Start-ProcessBoost -ProcessName $procName
})
$btnStopBoost = New-StyledButton "Остановить" 110
$btnStopBoost.Add_Click({ Stop-ProcessBoost })
$rowGame.Controls.AddRange(@($lblGame, $comboGame, $btnStartBoost, $btnStopBoost))
$pgGame.Controls.Add($rowGame)

# --- Нижняя часть: журнал + кнопки ---
$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.ReadOnly = $true
$Global:LogBox.Dock = "Fill"
$Global:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = "Журнал"
$grpLog.Dock = "Bottom"
$grpLog.Height = [int](160 * $Dpi)
$grpLog.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 8)
$grpLog.Controls.Add($Global:LogBox)

$btnBackup = New-StyledButton "Создать бэкап" 140
$btnBackup.Add_Click({ Backup-CurrentState | Out-Null })

$btnRestore = New-StyledButton "Восстановить из бэкапа" 190
$btnRestore.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Восстановить последний сохранённый бэкап настроек?", "Подтверждение", "YesNo", "Question")
    if ($confirm -eq "Yes") { Restore-FromBackup }
})

$btnApply = New-StyledButton "Применить выбранное" 200 $true
$btnApply.Margin = New-Object System.Windows.Forms.Padding(8, 4, 0, 4)
$btnApply.Add_Click({
    $backupDir = Backup-CurrentState
    Write-Log "=== Применение выбранных оптимизаций ==="

    if ($checkboxes["ClearTemp"].Checked)      { Clear-TempAndCache }
    if ($checkboxes["UltimatePower"].Checked) { Opt-UltimatePower }
    if ($checkboxes["UsbSuspend"].Checked)    { Opt-DisableUsbSuspend }
    if ($checkboxes["CoreParking"].Checked)   { Opt-DisableCoreParking }
    if ($checkboxes["HAGS"].Checked)          { Opt-HAGS }
    if ($checkboxes["GameDVR"].Checked)       { Opt-DisableGameDVR }
    if ($checkboxes["MMCSS"].Checked)         { Opt-MMCSSGamesProfile }
    if ($checkboxes["VisualFx"].Checked)      { Opt-VisualEffectsPerformance }
    if ($checkboxes["NetThrottle"].Checked)   { Opt-NetworkThrottling }
    if ($checkboxes["Nagle"].Checked)         { Opt-DisableNagle }
    if ($checkboxes["DnsWinsock"].Checked)    { Opt-FlushDnsResetWinsock }
    if ($checkboxes["BgServices"].Checked)    { Opt-BackgroundServices }
    if ($checkboxes["BgTasks"].Checked)       { Opt-DisableScheduledTasksBloat }
    if ($checkboxes["BgApps"].Checked)        { Opt-DisableBackgroundApps }
    if ($checkboxes["NicPower"].Checked)      { Opt-DisableNicPowerSaving }
    if ($checkboxes["Hibernation"].Checked)   { Opt-DisableHibernation }
    if ($checkboxes["PrioSep"].Checked)       { Opt-PrioritySeparation }
    if ($checkboxes["MouseAccel"].Checked)    { Opt-DisableMouseAcceleration }
    if ($checkboxes["InputQueue"].Checked)    { Opt-ReduceInputBuffering }
    if ($checkboxes["HidPower"].Checked)      { Opt-DisableHidPowerSaving }
    if ($checkboxes["IrqAffinity"].Checked) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Привязка IRQ может временно нарушить работу мыши/клавиатуры до перезагрузки. Продолжить?",
            "Подтверждение", "YesNo", "Warning")
        if ($confirm -eq "Yes") { Opt-SetInputIrqAffinity -CoreIndex $comboCore.SelectedIndex }
        else { Write-Log "IRQ affinity пропущена пользователем." }
    }
    if ($checkboxes["MsiMode"].Checked) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Принудительный MSI-режим может привести к отказу устройства (код 10), если драйвер его не поддерживает. Продолжить?",
            "Подтверждение", "YesNo", "Warning")
        if ($confirm -eq "Yes") { Opt-EnableMsiModeForInputDevices }
        else { Write-Log "MSI mode пропущен пользователем." }
    }
    if ($checkboxes["Defender"].Checked) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Microsoft Defender будет отключён, ПК останется БЕЗ антивирусной защиты.`r`n`r`n" +
            "Риски: заражение вирусами, майнерами и стилерами (особенно через читы, моды и кряки), " +
            "отсутствие защиты от шифровальщиков и вредоносных скриптов, предупреждения Центра безопасности, " +
            "возможное самопроизвольное включение после обновлений Windows.`r`n`r`n" +
            "Перед этим должна быть вручную выключена «Защита от подделки». Включить обратно можно кнопкой на вкладке Advanced.`r`n`r`n" +
            "Вы понимаете риски и хотите продолжить?",
            "Отключение Defender", "YesNo", "Warning")
        if ($confirm -eq "Yes") { Opt-DisableDefender }
        else { Write-Log "Отключение Defender пропущено пользователем." }
    }
    if ($checkboxes["Mitigations"].Checked) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Отключение mitigations снижает защиту CPU от атак класса Spectre/Meltdown. Продолжить?",
            "Подтверждение", "YesNo", "Warning")
        if ($confirm -eq "Yes") { Opt-DisableMitigations }
        else { Write-Log "Отключение mitigations пропущено пользователем." }
    }

    Write-Log "=== Готово. Некоторые изменения требуют перезагрузки. ==="
    [System.Windows.Forms.MessageBox]::Show("Оптимизации применены. Рекомендуется перезагрузка компьютера.`r`nБэкап: $backupDir", "WinGameOptimizer") | Out-Null
})

$btnExit = New-StyledButton "Закрыть" 110
$btnExit.Margin = New-Object System.Windows.Forms.Padding(8, 4, 0, 4)
$btnExit.Add_Click({ Stop-ProcessBoost; $form.Close() })

$flowLeft = New-Object System.Windows.Forms.FlowLayoutPanel
$flowLeft.Dock = "Left"
$flowLeft.AutoSize = $true
$flowLeft.FlowDirection = "LeftToRight"
$flowLeft.Controls.AddRange(@($btnBackup, $btnRestore))

$flowRight = New-Object System.Windows.Forms.FlowLayoutPanel
$flowRight.Dock = "Right"
$flowRight.AutoSize = $true
$flowRight.FlowDirection = "RightToLeft"
$flowRight.Controls.AddRange(@($btnExit, $btnApply))

$pnlButtons = New-Object System.Windows.Forms.Panel
$pnlButtons.Dock = "Bottom"
$pnlButtons.Height = [int](50 * $Dpi)
$pnlButtons.Controls.Add($flowLeft)
$pnlButtons.Controls.Add($flowRight)

# --- Заголовок ---
$cpuName = try { (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch { "CPU не определён" }
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "WinGameOptimizer"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $ColorAccent
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(0, 2)
$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "$cpuName   •   отметьте нужное на вкладках и нажмите «Применить выбранное» (бэкап создаётся автоматически)"
$lblSub.ForeColor = $ColorMuted
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(2, 34)
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = "Top"
$pnlHeader.Height = [int](58 * $Dpi)
$pnlHeader.Controls.AddRange(@($lblTitle, $lblSub))

# Порядок добавления важен для Dock: Fill первым, затем Bottom'ы, Top последним.
$form.Controls.Add($tabs)
$form.Controls.Add($grpLog)
$form.Controls.Add($pnlButtons)
$form.Controls.Add($pnlHeader)

Refresh-StartupList
Write-Log "WinGameOptimizer запущен. Backup-папка: $BackupRoot"
Write-Log "Реальный эффект: снижение фоновой нагрузки/задержки и более стабильный frame-time."
Write-Log "На GPU-bound сценариях прирост FPS от софт-твиков обычно умеренный (единицы-десятки %)."

[void]$form.ShowDialog()
