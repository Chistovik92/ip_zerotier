<#
.SYNOPSIS
  Подключает Windows-компьютер к сети ZeroTier-«модема» (zt_exitnode.sh):
  ставит ZeroTier, входит в сеть, включает/выключает VPN через сервер
  и настраивает адаптер для игр по локальной сети.

.EXAMPLE
  # VPN + игры по LAN
  powershell -ExecutionPolicy Bypass -File .\zt-client.ps1 -NetworkId 8056c2e21c000001 -Vpn on
.EXAMPLE
  # Только LAN для игр, интернет напрямую
  powershell -ExecutionPolicy Bypass -File .\zt-client.ps1 -NetworkId 8056c2e21c000001 -Vpn off
.EXAMPLE
  # Выйти из сети
  powershell -ExecutionPolicy Bypass -File .\zt-client.ps1 -NetworkId 8056c2e21c000001 -Leave
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{16}$')]
    [string]$NetworkId,

    [ValidateSet('on', 'off')]
    [string]$Vpn = 'on',

    # DNS, который используется при включённом VPN (запросы идут через сервер)
    [string[]]$Dns = @('1.1.1.1', '8.8.8.8'),

    # Не менять метрику адаптера (по умолчанию ставим 1, чтобы игры искали LAN-серверы в ZeroTier)
    [switch]$NoMetric,

    [switch]$Leave
)

$ErrorActionPreference = 'Stop'
$NetworkId = $NetworkId.ToLower()
# при запуске через -File массив приходит одной строкой "1.1.1.1,8.8.8.8"
$Dns = @($Dns | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

# --- права администратора (перезапуск с UAC) ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-NetworkId', $NetworkId, '-Vpn', $Vpn, '-Dns', ($Dns -join ','))
    if ($NoMetric) { $argList += '-NoMetric' }
    if ($Leave)    { $argList += '-Leave' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  $msg" }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

function Get-ZtExe {
    foreach ($name in 'zerotier-one_x64.exe', 'zerotier-one_arm64.exe', 'zerotier-one_x86.exe') {
        $p = Join-Path $env:ProgramData "ZeroTier\One\$name"
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Invoke-Zt {
    & $script:ZtExe -q @args
}

function Get-ZtNetwork {
    $json = Invoke-Zt -j listnetworks | Out-String
    if (-not $json.Trim()) { return $null }
    return ($json | ConvertFrom-Json) | Where-Object { $_.nwid -eq $NetworkId } | Select-Object -First 1
}

Write-Host "`nZeroTier client setup — сеть $NetworkId`n" -ForegroundColor Cyan

# --- установка ZeroTier ---
$script:ZtExe = Get-ZtExe
if (-not $script:ZtExe) {
    Info 'ZeroTier не установлен.'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info 'Устанавливаю через winget...'
        winget install --id ZeroTier.ZeroTierOne -e --silent --accept-source-agreements --accept-package-agreements | Out-Host
        Start-Sleep -Seconds 5
        $script:ZtExe = Get-ZtExe
    }
    if (-not $script:ZtExe) {
        Warn 'Скачайте и установите ZeroTier: https://www.zerotier.com/download/ , затем запустите скрипт снова.'
        Start-Process 'https://www.zerotier.com/download/'
        Read-Host 'Нажмите Enter для выхода'
        exit 1
    }
}
Ok "ZeroTier: $(Invoke-Zt -v)"

# --- выход из сети ---
if ($Leave) {
    Invoke-Zt leave $NetworkId | Out-Null
    Ok "Вы вышли из сети $NetworkId"
    Read-Host 'Нажмите Enter для выхода'
    exit 0
}

# --- вход в сеть ---
$info = (Invoke-Zt info) -split ' '
$nodeId = $info[2]
Invoke-Zt join $NetworkId | Out-Null
Start-Sleep -Seconds 2
$allowDefault = if ($Vpn -eq 'on') { 1 } else { 0 }
Invoke-Zt set $NetworkId allowManaged=1 | Out-Null
Invoke-Zt set $NetworkId "allowDefault=$allowDefault" | Out-Null
Invoke-Zt set $NetworkId allowDNS=0 | Out-Null
Ok "Подключаюсь к сети $NetworkId (ID этого компьютера: $nodeId)"

# --- ждём авторизации ---
$net = $null; $shown = $false
for ($i = 0; $i -lt 300; $i += 3) {
    $net = Get-ZtNetwork
    $ipv4 = @($net.assignedAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/' })
    if ($net -and $net.status -eq 'OK' -and $ipv4.Count -gt 0) { break }
    if (-not $shown -and $net -and $net.status -eq 'ACCESS_DENIED') {
        Warn "Компьютер ещё не авторизован в сети."
        Info "Попросите владельца сети отметить Auth для узла $nodeId (или на сервере: sudo zt-modem members)."
        Info "Жду до 5 минут..."
        $shown = $true
    }
    Start-Sleep -Seconds 3
}
if (-not $net -or $net.status -ne 'OK' -or $ipv4.Count -eq 0) {
    Warn "Не удалось получить адрес в сети (статус: $($net.status)). Запустите скрипт снова после авторизации."
    Read-Host 'Нажмите Enter для выхода'
    exit 1
}
Ok "В сети, IP: $($ipv4 -join ', ')"

# --- адаптер ZeroTier ---
$mac = ($net.mac -replace ':', '-').ToUpper()
$adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.MacAddress -eq $mac } | Select-Object -First 1
if (-not $adapter) {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like 'ZeroTier*' -and $_.Name -like "*$NetworkId*" } | Select-Object -First 1
}
if ($adapter) {
    $idx = $adapter.ifIndex
    try {
        Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private
        Ok "Сеть ZeroTier помечена как «Частная» (игры и ping между друзьями не режутся брандмауэром)"
    } catch { Warn "Не удалось сделать сеть частной: $($_.Exception.Message)" }

    if (-not $NoMetric) {
        try {
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -InterfaceMetric 1
            Ok 'Метрика адаптера = 1 (игры ищут LAN-серверы в ZeroTier)'
        } catch { Warn "Не удалось изменить метрику: $($_.Exception.Message)" }
    }

    try {
        if ($Vpn -eq 'on') {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $Dns
            Ok "DNS через VPN: $($Dns -join ', ')"
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
        }
        Clear-DnsClientCache
    } catch { Warn "Не удалось настроить DNS: $($_.Exception.Message)" }
} else {
    Warn 'Не нашёл сетевой адаптер ZeroTier — пропускаю настройку профиля/метрики/DNS.'
}

# --- проверка ---
Start-Sleep -Seconds 3
$gw = @($net.routes | Where-Object { $_.target -eq '0.0.0.0/0' } | ForEach-Object { $_.via })
try { $pub = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8 } catch { $pub = '?' }

Write-Host ''
if ($Vpn -eq 'on') {
    if ($gw.Count -eq 0) {
        Warn 'В сети нет маршрута 0.0.0.0/0 — VPN не заработает (владельцу сети нужно запустить zt_exitnode.sh или добавить маршрут).'
    } else {
        Ok "VPN включён через $($gw -join ', '). Ваш внешний IP сейчас: $pub"
    }
    Info 'IPv6 идёт мимо VPN. Если Discord/Telegram всё равно не работают — отключите IPv6 на основном адаптере.'
} else {
    Ok "Режим «только LAN»: интернет идёт напрямую (внешний IP: $pub)"
}
Info "Игры: выбирайте «Сетевая игра / LAN» или подключайтесь по IP друга из сети ZeroTier."
Info "Переключить режим: запустите скрипт с -Vpn on или -Vpn off."
Write-Host ''
Read-Host 'Нажмите Enter для выхода'
