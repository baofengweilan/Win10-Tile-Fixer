#Requires -Version 7.0
<#
.SYNOPSIS
  Win10 Tile Fixer - Windows 10 开始菜单磁贴布局修复工具

.DESCRIPTION
  治疗磁贴经典绝症：
    - 新固定的磁贴沉底，之后拖不动
    - 磁贴上移后被弹回原位
    - 取消固定后最下方残留"幽灵磁贴"
    - 布局改完不保存 / 重启后被打回原形

  病根：开始菜单磁贴布局缓存（注册表 CloudStore 键）损坏膨胀。
  网上流传的修法（杀 explorer 后删注册表键）经常无效：CDPUserSvc /
  OneSyncSvc 等按用户服务会把内存里的旧布局原样写回。
  本工具的完整流程：
    1. 备份 CloudStore 到本地 .reg 文件
    2. 终止全部写入方（承载 CDPUserSvc/OneSyncSvc 的 svchost +
       StartMenuExperienceHost + ShellExperienceHost + explorer）
    3. 删除 CloudStore
    4. 等待 1.5 秒校验"没有被回写"（被回写则自动重试一次）
    5. 重启资源管理器，Windows 用干净数据重建布局

  于 2026-11 在 Windows 10 22H2 (build 19045) 实机验证：
  病态数据 7.4 MB -> 重建后 74 KB，拖动/固定/重启均正常。

.PARAMETER Action
  diagnose  只读体检（默认值）
  fix       执行修复（会先自动备份；磁贴布局将重置为默认）
  restore   从备份恢复布局（注意：会把坏数据也一起恢复）

.PARAMETER BackupFile
  restore 模式：指定要恢复的 .reg 备份文件路径

.PARAMETER Force
  跳过交互确认（用于脚本化）

.EXAMPLE
  pwsh -File TileFixer.ps1                          # 交互菜单
  pwsh -File TileFixer.ps1 -Action diagnose         # 只读体检
  pwsh -File TileFixer.ps1 -Action fix              # 备份并修复
  pwsh -File TileFixer.ps1 -Action fix -Force       # 不询问直接修
  pwsh -File TileFixer.ps1 -Action restore -BackupFile .\Backups\xxx.reg

.NOTES
  不需要管理员权限（按用户服务可由当前用户终止）。
  若写入方终止失败，脚本会提示并继续，修复后请重跑 diagnose 复查。
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('diagnose', 'fix', 'restore')]
    [string]$Action,

    [string]$BackupFile,

    [switch]$Force
)

$script:Version       = '1.0.0'
$script:CloudStore    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore'
$script:CloudStoreReg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore'
$script:DiskCache     = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\CloudStore'
$script:ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BackupDir     = Join-Path $ScriptDir 'Backups'
$script:WriterSvcRe   = '^(CDPUserSvc|OneSyncSvc|UserDataPlatformSvc)_'
$script:StartProcs    = 'StartMenuExperienceHost', 'ShellExperienceHost', 'explorer'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------- 输出辅助 ----------------

function Write-Step { param([string]$m) Write-Host "  [*] $m" }
function Write-Ok   { param([string]$m) Write-Host "  [+] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "  [x] $m" -ForegroundColor Red }

function Write-Banner {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host " Win10 Tile Fixer v$Version  -  开始菜单磁贴修复" -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Wait-Enter { param([string]$m = '按回车键继续...') Read-Host "  $m" | Out-Null }

# ---------------- 健康检查 ----------------

function Get-CloudStoreHealth {
    $bytes = 0; $entries = 0; $graveyard = $false; $tilegrid = $false
    if (Test-Path $CloudStore) {
        $items = Get-ChildItem $CloudStore -Recurse -ErrorAction SilentlyContinue
        $entries = ($items | Measure-Object).Count
        foreach ($item in $items) {
            if ($item.PSChildName -like '*graveyard*') { $graveyard = $true }
            if ($item.PSChildName -like '*start.tilegrid*') { $tilegrid = $true }
            $props = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($v in $props.PSObject.Properties) {
                    if ($v.Value -is [byte[]]) { $bytes += $v.Value.Length }
                }
            }
        }
    }
    [pscustomobject]@{
        Exists      = (Test-Path $CloudStore)
        BinaryBytes = $bytes
        ItemCount   = $entries
        Graveyard   = $graveyard
        TileGrid    = $tilegrid
    }
}

function Get-HealthVerdict {
    param([int]$Bytes)
    if ($Bytes -ge 2MB)        { return '损坏(膨胀)', 'Red' }
    elseif ($Bytes -ge 300KB)  { return '警惕', 'Yellow' }
    elseif ($Bytes -gt 0)      { return '健康', 'Green' }
    else                       { return '空/未知', 'Gray' }
}

# ---------------- 诊断 ----------------

function Invoke-Diagnose {
    Write-Banner

    Write-Host '  一、系统兼容性'
    $build = [Environment]::OSVersion.Version.Build
    if ($build -ge 22000) {
        Write-Warn2 "当前是 Windows 11 (build $build)。磁贴机制相同，但本工具未在 Win11 充分测试，仅供尝试。"
    }
    elseif ($build -lt 16299) {
        Write-Err2 "当前 build $build 属于 TileDataLayer 时代 (1709 之前)，不适用本工具。"
        Write-Host '      官方方案: C:\Windows\System32\tdlrecover.exe -reregister -resetlayout -resetcache'
        return
    }
    else {
        Write-Ok "Windows 10 build $build (Tile Store / CloudStore 时代)，适用。"
    }
    Write-Host ''

    Write-Host '  二、磁贴布局缓存 (CloudStore) 健康度'
    $h = Get-CloudStoreHealth
    if (-not $h.Exists) {
        Write-Warn2 'CloudStore 键不存在（可能从未生成或已被重置）。'
    }
    else {
        $verdict = Get-HealthVerdict -Bytes $h.BinaryBytes
        Write-Host ("      二进制数据量 : {0:N0} 字节" -f $h.BinaryBytes)
        Write-Host ("      注册表条目数 : {0}" -f $h.ItemCount)
        Write-Host ("      磁贴网格     : {0}" -f $(if ($h.TileGrid) { '存在' } else { '不存在' }))
        Write-Host ("      墓碑区       : {0}" -f $(if ($h.Graveyard) { '存在(正常)' } else { '不存在' }))
        Write-Host '      健康判定     : ' -NoNewline
        Write-Host $verdict[0] -ForegroundColor $verdict[1]
        Write-Host '      (参考: 健康约为几十~几百 KB; 已知病灶可达 7.4 MB)'
    }
    Write-Host ''

    Write-Host '  三、开始布局策略检查 (布局被锁死时本工具无效)'
    $pm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\Current\device\Experience' -ErrorAction SilentlyContinue
    if ($pm -and $pm.StartLayout_ProviderSet -eq 1) {
        Write-Err2 '检测到 MDM 开始布局策略 (StartLayout_ProviderSet=1): 布局会被策略强制重铺。'
    }
    else {
        Write-Ok '无 MDM 布局策略。'
    }
    $foundPolicy = $false
    foreach ($pk in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer', 'HKCU:\Software\Policies\Microsoft\Windows\Explorer') {
        $p = Get-ItemProperty $pk -ErrorAction SilentlyContinue
        if ($p -and ($p.StartLayoutFile -or $p.LockedStartLayout)) { $foundPolicy = $true }
    }
    if ($foundPolicy) { Write-Err2 '检测到组策略 StartLayoutFile/LockedStartLayout: 布局被锁定。' }
    else { Write-Ok '无组策略布局锁定。' }
    Write-Host ''

    Write-Host '  四、近期磁贴写入错误 (事件日志, 近 7 天)'
    $cut = (Get-Date).AddDays(-7)
    $errs = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-ShellCommon-StartLayoutPopulation/Operational'
        Id        = 17, 21
        StartTime = $cut
    } -ErrorAction SilentlyContinue
    $n = ($errs | Measure-Object).Count
    if ($n -gt 0) {
        Write-Warn2 "发现 $n 条磁贴写入/初始化错误 (事件 ID 17/21):"
        $errs | Select-Object -First 3 | ForEach-Object {
            Write-Host ("      {0}  {1}" -f $_.TimeCreated, ($_.Message -split "`n")[0])
        }
        Write-Host '      (若集中出现在某次修复后首次打开开始菜单且不再增长, 属重建期竞态, 可忽略)'
    }
    else {
        Write-Ok '近 7 天无磁贴写入错误。'
    }
    Write-Host ''

    Write-Host '  五、开始菜单快捷方式重复扫描 (幽灵磁贴的另一病根)'
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }
    if ($shell) {
        $dirs = @(
            (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        )
        $lnks = foreach ($d in $dirs) { Get-ChildItem $d -Recurse -Filter *.lnk -ErrorAction SilentlyContinue }
        $map = foreach ($l in $lnks) {
            $t = $null
            try { $t = $shell.CreateShortcut($l.FullName).TargetPath } catch { }
            [pscustomobject]@{ Name = $l.BaseName; Path = $l.FullName; Target = $t }
        }
        $dups = $map | Where-Object { $_.Target } | Group-Object { $_.Target + '|' + $_.Name } | Where-Object Count -gt 1
        if ($dups) {
            Write-Warn2 ("发现 {0} 组同名同目标的重复快捷方式 (会在开始菜单重复出现):" -f @($dups).Count)
            $dups | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
                Write-Host ("      x{0}  {1}" -f $_.Count, $_.Group[0].Name)
                $_.Group | ForEach-Object { Write-Host ("          {0}" -f $_.Path) }
            }
            Write-Host '      (可手动删除多余的一份; 不影响程序本体)'
        }
        else {
            Write-Ok '未发现同目标重复快捷方式。'
        }
    }
    else {
        Write-Warn2 '无法创建 COM 对象, 跳过快捷方式扫描。'
    }
    Write-Host ''
    Write-Host '  诊断完毕。若健康判定为"损坏(膨胀)"且磁贴行为异常, 运行:'
    Write-Host '      pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action fix'
}

# ---------------- 修复 ----------------

function Invoke-Fix {
    Write-Banner

    # 0. 前置检查
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 16299) {
        Write-Err2 "build $build 不适用本工具 (1709 之前的 TileDataLayer 时代)。"
        return
    }
    if (-not (Test-Path $CloudStore)) {
        Write-Warn2 'CloudStore 键不存在, 无需修复。'
        return
    }

    # 1. 备份
    try {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bakFile = Join-Path $BackupDir "CloudStore-backup-$stamp.reg"
        Write-Step '备份磁贴布局数据...'
        & reg.exe export $CloudStoreReg $bakFile /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'reg export 失败' }
        Write-Ok "已备份: $bakFile"
        if (Test-Path $DiskCache) {
            $bakDir2 = Join-Path $BackupDir "CloudStore-folder-$stamp"
            Copy-Item $DiskCache $bakDir2 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "已备份磁盘缓存文件夹: $bakDir2"
        }
    }
    catch {
        Write-Err2 "备份失败: $_  (中止修复, 未做任何更改)"
        return
    }

    # 2. 确认
    Write-Host ''
    Write-Warn2 '修复会把磁贴布局重置为出厂默认 (所有应用列表不受影响), 修复后需重新摆放磁贴。'
    if (-not $Force) {
        $a = Read-Host '  确认继续? (y/N)'
        if ($a -notmatch '^[yY]') { Write-Host '  已取消, 未做任何更改。'; return }
    }

    # 3. 终止写入方
    Write-Step '终止 CloudStore 写入方 (承载按用户同步服务的 svchost)...'
    $failedSvcs = @()
    $svcPids = Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $WriterSvcRe } |
        Select-Object -ExpandProperty ProcessId -Unique
    if ($svcPids) {
        foreach ($spid in $svcPids) {
            try { Stop-Process -Id $spid -Force -ErrorAction Stop } catch { $failedSvcs += $spid }
        }
        Write-Ok ("已终止 {0} 个写入方进程。" -f (@($svcPids).Count - @($failedSvcs).Count))
        if (@($failedSvcs).Count -gt 0) {
            Write-Warn2 ("有 {0} 个 svchost 终止失败 (权限不足?), 将尝试继续; 修复后请重跑 diagnose 复查。" -f @($failedSvcs).Count)
        }
    }
    else {
        Write-Ok '当前没有运行中的写入方服务。'
    }

    Write-Step '终止开始菜单宿主与资源管理器...'
    foreach ($pn in $StartProcs) {
        Get-Process $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800

    # 4. 删除 + 校验 (关键步骤: 确认没有被内存回写)
    Write-Step '删除损坏的布局缓存...'
    & reg.exe delete $CloudStoreReg /f 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1500
    if (Test-Path $CloudStore) {
        Write-Warn2 '检测到键被回写, 重杀写入方后再删一次...'
        Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $WriterSvcRe } |
            Select-Object -ExpandProperty ProcessId -Unique |
            ForEach-Object { try { Stop-Process -Id $_ -Force -ErrorAction Stop } catch { } }
        & reg.exe delete $CloudStoreReg /f 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
    }
    if (Test-Path $CloudStore) {
        Write-Err2 'CloudStore 仍被回写, 本次未能清除。'
        Write-Host '      建议: 重启电脑后立即重试, 或进入安全模式运行本命令。'
        Start-Process explorer.exe
        return
    }
    Write-Ok '布局缓存已清除且确认未被回写。'

    # 5. 重启资源管理器
    Write-Step '重启资源管理器...'
    Start-Process explorer.exe
    Start-Sleep -Milliseconds 1500
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Write-Ok '资源管理器已重启。'
    }
    else {
        Write-Warn2 '资源管理器未自动出现: 打开任务管理器 -> 文件 -> 运行新任务 -> 输入 explorer.exe'
    }

    Write-Host ''
    Write-Ok "修复完成 (v$Version)。打开开始菜单, 重新固定、摆放磁贴 - 这次位置会真正保存。"
    Write-Host "  布局备份位置: $bakFile"
    Write-Host "  如需恢复: pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action restore -BackupFile `"$bakFile`""
}

# ---------------- 恢复 ----------------

function Invoke-Restore {
    Write-Banner
    if (-not $BackupFile) {
        Write-Err2 '缺少 -BackupFile 参数。示例:'
        Write-Host '      pwsh -File .\TileFixer.ps1 -Action restore -BackupFile .\Backups\CloudStore-backup-xxx.reg'
        return
    }
    if (-not (Test-Path $BackupFile)) {
        Write-Err2 "找不到备份文件: $BackupFile"
        return
    }
    Write-Warn2 '恢复会把备份时的布局 (含当时已损坏的数据) 原样写回。'
    if (-not $Force) {
        $a = Read-Host '  确认恢复? (y/N)'
        if ($a -notmatch '^[yY]') { Write-Host '  已取消。'; return }
    }
    Write-Step '停止资源管理器与开始菜单宿主...'
    foreach ($pn in $StartProcs) {
        Get-Process $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
    Write-Step "导入备份: $BackupFile"
    & reg.exe import $BackupFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 '导入失败, 请检查文件是否为 reg export 生成的 .reg。'
        Start-Process explorer.exe
        return
    }
    Write-Ok '导入完成。'
    Start-Process explorer.exe
    Write-Ok '已恢复并重启资源管理器。'
}

# ---------------- 交互菜单 ----------------

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Banner
        Write-Host '  [1] 体检诊断 (只读, 不做任何更改)'
        Write-Host '  [2] 执行修复 (自动备份 -> 布局重置为默认)'
        Write-Host '  [3] 从备份恢复'
        Write-Host '  [4] 退出'
        $c = Read-Host '  请选择'
        switch ($c) {
            '1' { Invoke-Diagnose; Wait-Enter }
            '2' { Invoke-Fix; Wait-Enter }
            '3' { Invoke-Restore; Wait-Enter }
            '4' { return }
        }
    }
}

# ---------------- 入口 ----------------

if (-not $Action) {
    if ([Environment]::UserInteractive) { Show-Menu } else { Invoke-Diagnose }
}
else {
    switch ($Action) {
        'diagnose' { Invoke-Diagnose }
        'fix'      { Invoke-Fix }
        'restore'  { Invoke-Restore }
    }
}
