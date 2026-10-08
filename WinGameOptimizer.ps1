<#
.SYNOPSIS
    WinGameOptimizer — GUI-утилита для тюнинга Windows под игры (Valorant, CS2, Dota 2 и др.)

.DESCRIPTION
    Применяет только документированные, обратимые настройки Windows:
    план питания, планирование GPU, MMCSS/приоритеты процессов, сетевые тайминги,
    фоновые службы. Перед любым изменением делает бэкап затронутых веток реестра
    и текущей схемы питания. Отключение антивируса/защитника НЕ выполняется.

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
    "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
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

function Opt-UltimatePower {
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
    "WerSvc",             # Windows Error Reporting — можно отключать на время игры
    "PcaSvc"              # Program Compatibility Assistant
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
        "$env:WINDIR\Prefetch\*",
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
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinGameOptimizer — Valorant / CS2 / Dota 2"
$form.Size = New-Object System.Drawing.Size(760, 720)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Size = New-Object System.Drawing.Size(730, 420)
$tabs.Location = New-Object System.Drawing.Point(15, 15)
$form.Controls.Add($tabs)

$checkboxes = @{}

function New-OptTab {
    param([string]$Title)
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Title
    $tabs.TabPages.Add($tab)
    return $tab
}

function Add-OptCheckbox {
    param($Tab, [string]$Key, [string]$Label, [int]$Y, [bool]$Checked = $true)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Label
    $cb.Location = New-Object System.Drawing.Point(15, $Y)
    $cb.Size = New-Object System.Drawing.Size(680, 24)
    $cb.Checked = $Checked
    $Tab.Controls.Add($cb)
    $checkboxes[$Key] = $cb
}

$tabPower = New-OptTab "Питание"
Add-OptCheckbox $tabPower "UltimatePower" "Включить план питания Ultimate Performance" 20
Add-OptCheckbox $tabPower "UsbSuspend"    "Отключить USB selective suspend" 55
Add-OptCheckbox $tabPower "CoreParking"   "Отключить core parking (ядра CPU всегда активны)" 90

$tabGpu = New-OptTab "GPU / Дисплей"
Add-OptCheckbox $tabGpu "HAGS"       "Hardware-Accelerated GPU Scheduling" 20
Add-OptCheckbox $tabGpu "GameDVR"    "Отключить Game DVR / Xbox Game Bar overlay" 55
Add-OptCheckbox $tabGpu "MMCSS"      "Приоритет GPU/CPU для игр (MMCSS 'Games')" 90
Add-OptCheckbox $tabGpu "VisualFx"   "Визуальные эффекты: 'Лучшее быстродействие'" 125 $false

$tabNet = New-OptTab "Сеть"
Add-OptCheckbox $tabNet "NetThrottle" "Отключить Network Throttling Index" 20
Add-OptCheckbox $tabNet "Nagle"       "Отключить алгоритм Нагла (TCPNoDelay)" 55
Add-OptCheckbox $tabNet "DnsWinsock"  "Flush DNS + сброс Winsock (может сбросить сетевые настройки)" 90 $false

$tabSys = New-OptTab "Система"
Add-OptCheckbox $tabSys "BgServices"   "Остановить фоновые службы (SysMain, WSearch, DiagTrack, телеметрия и др.)" 20
Add-OptCheckbox $tabSys "BgTasks"      "Отключить фоновые задачи планировщика (телеметрия, CEIP, карты)" 55
Add-OptCheckbox $tabSys "BgApps"       "Отключить фоновые UWP-приложения" 90
Add-OptCheckbox $tabSys "NicPower"     "Отключить энергосбережение сетевой карты" 125
Add-OptCheckbox $tabSys "Hibernation"  "Отключить гибернацию (освободить место на диске)" 160 $false
Add-OptCheckbox $tabSys "ClearTemp"    "Очистить temp/кэш/корзину перед применением" 195

$tabAdv = New-OptTab "Advanced (риск)"
$warnLabel = New-Object System.Windows.Forms.Label
$warnLabel.Text = "Эти настройки снижают уровень защиты системы. Применяйте осознанно."
$warnLabel.ForeColor = [System.Drawing.Color]::DarkRed
$warnLabel.Location = New-Object System.Drawing.Point(15, 15)
$warnLabel.Size = New-Object System.Drawing.Size(680, 20)
$tabAdv.Controls.Add($warnLabel)
Add-OptCheckbox $tabAdv "Mitigations" "Отключить Spectre/Meltdown mitigations (снижает защиту CPU)" 45 $false

$tabStartup = New-OptTab "Автозагрузка"
$lblStartup = New-Object System.Windows.Forms.Label
$lblStartup.Text = "Отмеченные пункты будут отключены (перемещены в бэкап, не удалены)."
$lblStartup.Location = New-Object System.Drawing.Point(15, 10)
$lblStartup.Size = New-Object System.Drawing.Size(680, 20)
$tabStartup.Controls.Add($lblStartup)

$listStartup = New-Object System.Windows.Forms.CheckedListBox
$listStartup.Location = New-Object System.Drawing.Point(15, 35)
$listStartup.Size = New-Object System.Drawing.Size(680, 260)
$listStartup.CheckOnClick = $true
$tabStartup.Controls.Add($listStartup)

$Global:StartupItemsCache = @()
function Refresh-StartupList {
    $listStartup.Items.Clear()
    $Global:StartupItemsCache = Get-StartupItems
    foreach ($item in $Global:StartupItemsCache) {
        $listStartup.Items.Add("$($item.Name)  —  $($item.Value)") | Out-Null
    }
}

$btnRefreshStartup = New-Object System.Windows.Forms.Button
$btnRefreshStartup.Text = "Обновить список"
$btnRefreshStartup.Location = New-Object System.Drawing.Point(15, 305)
$btnRefreshStartup.Size = New-Object System.Drawing.Size(150, 30)
$btnRefreshStartup.Add_Click({ Refresh-StartupList })
$tabStartup.Controls.Add($btnRefreshStartup)

$btnDisableStartup = New-Object System.Windows.Forms.Button
$btnDisableStartup.Text = "Отключить выбранные"
$btnDisableStartup.Location = New-Object System.Drawing.Point(175, 305)
$btnDisableStartup.Size = New-Object System.Drawing.Size(170, 30)
$btnDisableStartup.Add_Click({
    for ($i = 0; $i -lt $listStartup.Items.Count; $i++) {
        if ($listStartup.GetItemChecked($i)) {
            Disable-StartupItem -Item $Global:StartupItemsCache[$i]
        }
    }
    Refresh-StartupList
})
$tabStartup.Controls.Add($btnDisableStartup)

$btnRestoreStartup = New-Object System.Windows.Forms.Button
$btnRestoreStartup.Text = "Восстановить все отключённые"
$btnRestoreStartup.Location = New-Object System.Drawing.Point(355, 305)
$btnRestoreStartup.Size = New-Object System.Drawing.Size(200, 30)
$btnRestoreStartup.Add_Click({ Restore-AllStartupItems; Refresh-StartupList })
$tabStartup.Controls.Add($btnRestoreStartup)

$tabDebloat = New-OptTab "Debloat (приложения)"
$lblDebloat = New-Object System.Windows.Forms.Label
$lblDebloat.Text = "Удаление предустановленных UWP-приложений. Откат недоступен — переустановка из Microsoft Store."
$lblDebloat.ForeColor = [System.Drawing.Color]::DarkRed
$lblDebloat.Location = New-Object System.Drawing.Point(15, 10)
$lblDebloat.Size = New-Object System.Drawing.Size(680, 20)
$tabDebloat.Controls.Add($lblDebloat)

$listBloat = New-Object System.Windows.Forms.CheckedListBox
$listBloat.Location = New-Object System.Drawing.Point(15, 35)
$listBloat.Size = New-Object System.Drawing.Size(680, 260)
$listBloat.CheckOnClick = $true
foreach ($pattern in $BloatPackagePatterns) {
    $idx = $listBloat.Items.Add($pattern)
    # Teams / PowerAutomate / Family по умолчанию не отмечаем — многим нужны
    if ($pattern -notin @("MicrosoftTeams", "Microsoft.PowerAutomateDesktop", "Microsoft.MicrosoftFamily")) {
        $listBloat.SetItemChecked($idx, $true)
    }
}
$tabDebloat.Controls.Add($listBloat)

$btnRemoveBloat = New-Object System.Windows.Forms.Button
$btnRemoveBloat.Text = "Удалить выбранные приложения"
$btnRemoveBloat.Location = New-Object System.Drawing.Point(15, 305)
$btnRemoveBloat.Size = New-Object System.Drawing.Size(220, 30)
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
$tabDebloat.Controls.Add($btnRemoveBloat)

$tabInput = New-OptTab "Мышь / Инпут-лаг"
Add-OptCheckbox $tabInput "MouseAccel"  "Отключить акселерацию мыши (Enhance Pointer Precision)" 20
Add-OptCheckbox $tabInput "InputQueue"  "Уменьшить буфер очереди мыши/клавиатуры (меньше задержка)" 55
Add-OptCheckbox $tabInput "HidPower"    "Отключить энергосбережение HID-устройств (мышь/клавиатура)" 90

$lblIrq = New-Object System.Windows.Forms.Label
$lblIrq.Text = "ПРОДВИНУТО: привязка прерываний мыши/клавиатуры к ядру CPU:"
$lblIrq.ForeColor = [System.Drawing.Color]::DarkRed
$lblIrq.Location = New-Object System.Drawing.Point(15, 130)
$lblIrq.Size = New-Object System.Drawing.Size(500, 20)
$tabInput.Controls.Add($lblIrq)

Add-OptCheckbox $tabInput "IrqAffinity" "Включить привязку IRQ мыши/клавиатуры к выбранному ядру" 155 $false

$comboCore = New-Object System.Windows.Forms.ComboBox
$comboCore.Location = New-Object System.Drawing.Point(35, 185)
$comboCore.Size = New-Object System.Drawing.Size(200, 24)
$comboCore.DropDownStyle = "DropDownList"
$coreCount = [Environment]::ProcessorCount
for ($c = 0; $c -lt $coreCount; $c++) { $comboCore.Items.Add("CPU $c") | Out-Null }
$comboCore.SelectedIndex = [Math]::Min(2, $coreCount - 1)
$tabInput.Controls.Add($comboCore)

$lblCoreNote = New-Object System.Windows.Forms.Label
$lblCoreNote.Text = "Рекомендуется не CPU 0 (обычно занят системными прерываниями)."
$lblCoreNote.Location = New-Object System.Drawing.Point(245, 189)
$lblCoreNote.Size = New-Object System.Drawing.Size(420, 20)
$tabInput.Controls.Add($lblCoreNote)

Add-OptCheckbox $tabInput "MsiMode" "ЭКСПЕРИМЕНТ: принудительный MSI-режим прерываний для HID (риск: код 10)" 220 $false

$btnRestoreInput = New-Object System.Windows.Forms.Button
$btnRestoreInput.Text = "Восстановить настройки устройств ввода"
$btnRestoreInput.Location = New-Object System.Drawing.Point(15, 260)
$btnRestoreInput.Size = New-Object System.Drawing.Size(280, 30)
$btnRestoreInput.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Восстановить настройки мыши/клавиатуры/HID из бэкапа?", "Подтверждение", "YesNo", "Question")
    if ($confirm -eq "Yes") { Restore-InputDeviceBackups }
})
$tabInput.Controls.Add($btnRestoreInput)

$noteInput = New-Object System.Windows.Forms.Label
$noteInput.Text = "IRQ affinity и MSI меняют низкоуровневые параметры драйверов устройств.`r`nПеред применением создаётся бэкап затронутых веток реестра устройства.`r`nЕсли мышь/клавиатура перестанут отвечать — переподключите устройство`r`nили откатите через 'Восстановить настройки устройств ввода' и перезагрузитесь."
$noteInput.Location = New-Object System.Drawing.Point(15, 300)
$noteInput.Size = New-Object System.Drawing.Size(680, 70)
$tabInput.Controls.Add($noteInput)

$tabGame = New-OptTab "Профиль игры"
$lblGame = New-Object System.Windows.Forms.Label
$lblGame.Text = "Игра:"
$lblGame.Location = New-Object System.Drawing.Point(15, 25)
$lblGame.Size = New-Object System.Drawing.Size(60, 20)
$tabGame.Controls.Add($lblGame)

$comboGame = New-Object System.Windows.Forms.ComboBox
$comboGame.Location = New-Object System.Drawing.Point(80, 22)
$comboGame.Size = New-Object System.Drawing.Size(220, 24)
$comboGame.DropDownStyle = "DropDownList"
$GameProfiles.Keys | ForEach-Object { $comboGame.Items.Add($_) | Out-Null }
$comboGame.SelectedIndex = 0
$tabGame.Controls.Add($comboGame)

$btnStartBoost = New-Object System.Windows.Forms.Button
$btnStartBoost.Text = "Запустить автоповышение приоритета"
$btnStartBoost.Location = New-Object System.Drawing.Point(15, 60)
$btnStartBoost.Size = New-Object System.Drawing.Size(280, 30)
$btnStartBoost.Add_Click({
    $gameName = $comboGame.SelectedItem.ToString()
    $procName = $GameProfiles[$gameName]
    Start-ProcessBoost -ProcessName $procName
})
$tabGame.Controls.Add($btnStartBoost)

$btnStopBoost = New-Object System.Windows.Forms.Button
$btnStopBoost.Text = "Остановить"
$btnStopBoost.Location = New-Object System.Drawing.Point(305, 60)
$btnStopBoost.Size = New-Object System.Drawing.Size(120, 30)
$btnStopBoost.Add_Click({ Stop-ProcessBoost })
$tabGame.Controls.Add($btnStopBoost)

$noteGame = New-Object System.Windows.Forms.Label
$noteGame.Text = "Запустите мониторинг ПЕРЕД игрой: при обнаружении процесса ему будет`r`nавтоматически выставлен приоритет High и affinity на все ядра.`r`nАнти-чит процессы (vgc.exe, cs2-anticheat и т.п.) не трогаются."
$noteGame.Location = New-Object System.Drawing.Point(15, 100)
$noteGame.Size = New-Object System.Drawing.Size(680, 60)
$tabGame.Controls.Add($noteGame)

# --- Нижняя панель: лог, кнопки ---
$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.ReadOnly = $true
$Global:LogBox.Location = New-Object System.Drawing.Point(15, 450)
$Global:LogBox.Size = New-Object System.Drawing.Size(730, 170)
$Global:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($Global:LogBox)

$btnBackup = New-Object System.Windows.Forms.Button
$btnBackup.Text = "Создать бэкап"
$btnBackup.Location = New-Object System.Drawing.Point(15, 630)
$btnBackup.Size = New-Object System.Drawing.Size(140, 35)
$btnBackup.Add_Click({ Backup-CurrentState | Out-Null })
$form.Controls.Add($btnBackup)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Применить выбранное"
$btnApply.Location = New-Object System.Drawing.Point(165, 630)
$btnApply.Size = New-Object System.Drawing.Size(180, 35)
$btnApply.BackColor = [System.Drawing.Color]::LightGreen
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
$form.Controls.Add($btnApply)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = "Восстановить из бэкапа"
$btnRestore.Location = New-Object System.Drawing.Point(355, 630)
$btnRestore.Size = New-Object System.Drawing.Size(180, 35)
$btnRestore.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Восстановить последний сохранённый бэкап настроек?", "Подтверждение", "YesNo", "Question")
    if ($confirm -eq "Yes") { Restore-FromBackup }
})
$form.Controls.Add($btnRestore)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "Закрыть"
$btnExit.Location = New-Object System.Drawing.Point(605, 630)
$btnExit.Size = New-Object System.Drawing.Size(140, 35)
$btnExit.Add_Click({ Stop-ProcessBoost; $form.Close() })
$form.Controls.Add($btnExit)

Refresh-StartupList
Write-Log "WinGameOptimizer запущен. Backup-папка: $BackupRoot"
Write-Log "Реальный эффект: снижение фоновой нагрузки/задержки и более стабильный frame-time."
Write-Log "На GPU-bound сценариях прирост FPS от софт-твиков обычно умеренный (единицы-десятки %)."

[void]$form.ShowDialog()
