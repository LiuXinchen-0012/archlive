<#
.NOTES
    ⚠️  如果你用 Ventoy，【不需要这个脚本】。
        Ventoy 装好一次之后，加 ISO 只是复制文件到 U 盘，不用擦盘。
        详见 测试与写盘-VMware-Ventoy.md
        本脚本仅在没有 Ventoy、或要 dd 风格裸写时使用。

.SYNOPSIS
    把 ARCH_SHORIN ISO 写入 U 盘（Windows 版，替代 dd）

.DESCRIPTION
    dd 在 Windows 上不存在，千万别照抄 Linux 的写法。
    这个脚本会：
      1. 列出所有可移动磁盘，让你选（不让你手打盘符，减少擦错盘的机会）
      2. 显示目标盘容量/型号，让你对着确认
      3. 先校验 ISO 的 SHA256（如果旁边有 sha256sum.txt）
      4. 要求你再输一次盘符确认
      5. 写入并做写后校验

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File write-usb.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File write-usb.ps1 -IsoFile D:\archlinux-shorin-1.0.0-x86_64.iso
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$IsoFile,

    [switch]$Force          # 跳过二次确认（不建议）
)

$ErrorActionPreference = 'Stop'

# ── 如果没指定 ISO，自动找当前目录下最新的 ──
if (-not $IsoFile) {
    $cand = Get-ChildItem -Path $PSScriptRoot, (Get-Location) -Filter 'archlinux-shorin-*.iso' `
            -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
    if ($cand) { $IsoFile = $cand[0].FullName }
}

if (-not $IsoFile) {
    Write-Host "找不到 ISO 文件。请用 -IsoFile 指定路径：" -ForegroundColor Red
    Write-Host "  powershell -ExecutionPolicy Bypass -File write-usb.ps1 -IsoFile D:\archlinux-shorin-1.0.0-x86_64.iso"
    exit 1
}
if (-not (Test-Path $IsoFile)) { Write-Host "文件不存在: $IsoFile" -ForegroundColor Red; exit 1 }
$IsoFile = (Resolve-Path $IsoFile).Path

$sizeGB = [math]::Round((Get-Item $IsoFile).Length / 1GB, 2)
Write-Host ""
Write-Host "ISO 文件: $IsoFile" -ForegroundColor Cyan
Write-Host "大小    : $sizeGB GB"
Write-Host ""

# ── 1. SHA256 校验 ──
$sumFile = [System.IO.Path]::ChangeExtension($IsoFile, $null) + 'sha256sum.txt'
if (-not (Test-Path $sumFile)) {
    $sumFile = Join-Path (Split-Path $IsoFile) 'sha256sum.txt'
}
if (Test-Path $sumFile) {
    $expected = ((Get-Content $sumFile -Raw) -split '\s+')[0].Trim().ToLower()
    Write-Host "正在校验 SHA256（ISO 有 5~6 GB，要一两分钟）..." -ForegroundColor Cyan
    $actual = (Get-FileHash $IsoFile -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Host ""
        Write-Host "✗ SHA256 不匹配 —— ISO 下载坏了或没下完" -ForegroundColor Red
        Write-Host "  期望: $expected"
        Write-Host "  实际: $actual"
        Write-Host "  请重新下载，不要写入这个文件。" -ForegroundColor Red
        exit 1
    }
    Write-Host "✓ SHA256 校验通过" -ForegroundColor Green
} else {
    Write-Host "! 没找到 sha256sum.txt，跳过校验" -ForegroundColor Yellow
}

# ── 2. 列出可移动磁盘 ──
Write-Host ""
Write-Host "可移动磁盘：" -ForegroundColor Cyan
$disks = Get-CimInstance Win32_DiskDrive | Where-Object { $_.DriveType -eq 'Removable' -or $_.InterfaceType -eq 'USB' }
if (-not $disks) { Write-Host "没检测到 USB 设备，插上再试" -ForegroundColor Red; exit 1 }

$disks | ForEach-Object {
    $letter = ($_.Partitions | ForEach-Object { $_.DriveLetter }) -join ''
    $vol = if ($letter) { (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue).FileSystemLabel } else { '' }
    Write-Host ("  磁盘 {0}  {1,-12} {2,7} GB  {3} {4}" -f `
        $_.DeviceID, $_.Model, [math]::Round($_.Size/1GB,1), $letter, $vol)
}

Write-Host ""
Write-Host "⚠  下面这一步会【彻底擦除】目标 U 盘上的所有数据。" -ForegroundColor Yellow
Write-Host "⚠  按物理盘符（如 \\.\PhysicalDrive2）输入，不要用盘符（E:）。" -ForegroundColor Yellow
Write-Host ""

$target = Read-Host "目标 PhysicalDrive 编号（0 / 1 / 2 ...）"
if (-not $Force) {
    $chosen = $disks | Where-Object { $_.DeviceID -eq "\\.\PhysicalDrive$target" }
    if (-not $chosen) { Write-Host "✗ 没有 PhysicalDrive$target" -ForegroundColor Red; exit 1 }
    $capGB = [math]::Round($chosen.Size / 1GB, 1)
    Write-Host ""
    Write-Host "即将擦除:" -ForegroundColor Yellow
    Write-Host "  设备   : $($chosen.DeviceID)" -ForegroundColor Yellow
    Write-Host "  型号   : $($chosen.Model)" -ForegroundColor Yellow
    Write-Host "  容量   : $capGB GB" -ForegroundColor Yellow
    Write-Host "  ISO 大 : $sizeGB GB" -ForegroundColor Yellow
    if ($capGB -lt ($sizeGB + 1)) {
        Write-Host ""
        Write-Host "✗ 目标盘比 ISO 还小，选错了吧？" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    $ok = Read-Host "确认擦除 $target 吗？输入 YES 继续"
    if ($ok -ne 'YES') { Write-Host "已取消。" -ForegroundColor Yellow; exit 0 }
}

# ── 3. 写入 ──
Write-Host ""
Write-Host "开始写入（进度条可能不动，raw 写入就是这样的，别以为卡死）..." -ForegroundColor Cyan
$fs = [System.IO.File]::Open($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    $in = [System.IO.File]::OpenRead($IsoFile)
    try {
        $buf = New-Object byte[] (4MB)
        $total = $in.Length
        $done = 0L
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $done += $n
            $pct = [math]::Round($done * 100.0 / $total, 1)
            $mbps = [math]::Round(($done / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.001), 1)
            Write-Progress -Activity "写入 U 盘" -Status "$pct%  |  $mbps MB/s  |  $([math]::Round(($total-$done)/1MB,0)) MB 剩余" -PercentComplete $pct
        }
        $fs.Flush($true)
    } finally { $in.Dispose() }
} finally { $fs.Dispose() }
Write-Progress -Activity "写入 U 盘" -Completed
Write-Host "✓ 写入完成，用时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒" -ForegroundColor Green

# ── 4. 卸载并提示 ──
$letterOf = ($disks | Where-Object { $_.DeviceID -eq $target }).Partitions |
            ForEach-Object { $_.DriveLetter }
foreach ($l in $letterOf) {
    if ($l) { Write-Host "正在弹出 $l`: ..." -ForegroundColor Cyan }
}
Get-Volume -DriveLetter $letterOf -ErrorAction SilentlyContinue |
    ForEach-Object { $d = $_.DriveLetter; Start-Process explorer -ArgumentList "${d}:\" -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "弹出前请关掉资源管理器里打开的 U 盘窗口，然后【安全弹出】。" -ForegroundColor Yellow
Write-Host ""
Write-Host "接下来：拿这个 U 盘去目标机器启动 → 选 'Download Arch' 图标 → 双击安装" -ForegroundColor Cyan
