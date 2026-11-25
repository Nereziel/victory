# Starts the game with the recommended settings and writes a log for every run.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\play.ps1 -Game "D:\Games\GTA VI\game_scarlett_master.exe"
#
# The game path is remembered in play.local.txt (not committed), so later runs need no argument.
# Each run writes logs\<date_time>\err.txt (the runtime's log) and out.txt. Share err.txt when reporting a crash.
param(
    [string]$Game = '',
    [switch]$Release,            # use target\release instead of target\diag
    [switch]$SeriesX,            # run as the larger console (about half the frame rate of the default Series S mode)
    [switch]$NoWarm,             # skip the shader warm-up even if this build has not done it
    [switch]$Warm,               # redo the shader warm-up even if this build already did it
    [ValidateSet('Baseline','AVX2','WideMerge','WideRefresh','CardWindows','ReBAR','MappingShards','HeapPlan','PipelineWindow','Balanced','Combined')]
    [string]$Benchmark = ''      # optional A/B test mode, one variable at a time
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$remember = Join-Path $root 'play.local.txt'
if (-not $Game -and (Test-Path $remember)) { $Game = (Get-Content $remember -Raw).Trim() }
if (-not $Game) { throw 'Pass -Game "<path to game_scarlett_master.exe>" once.' }
if (-not (Test-Path $Game)) { throw "Game executable not found: $Game" }
$Game = (Resolve-Path -LiteralPath $Game).ProviderPath
Set-Content -Path $remember -Value $Game -Encoding utf8

$build = if ($Release) { 'release' } else { 'diag' }
$exe = Join-Path $root "target\$build\victory.exe"
if (-not (Test-Path $exe)) {
    throw "Not built yet: $exe. Build first: cargo build --locked --profile diag -p victory --features diagnostics"
}

# Recommended preset (shadowdog00's, tested on an RTX 5060 Ti and an RX 6700 XT 12 GB).
# Cache and saves default to %LOCALAPPDATA%\victory.
$env:VICTORY_DISPLAY_MODE        = '1280x720'   # indoor walls draw with this
$env:VICTORY_SHADER_LOOP_LIMIT   = '256'        # without it the GPU hangs in the open world
$env:VICTORY_RELAY               = '2'
$env:VICTORY_INDIRECT_WINDOW     = '1'          # if the game loses the GPU, remove this first
$env:VICTORY_LATE_WAIT           = '3'
$env:VICTORY_WIDE_BACK           = '1'
$env:VICTORY_CARD_BUFFERS_MIN_MB = '1'
$env:VICTORY_CARD_BUFFERS_MB     = '1024'
$env:VICTORY_JOIN_COPIES         = '1'
$env:VICTORY_CARD_REHASH_RUNS    = '1'
# Named benchmark modes control only the experiment switches. The normal
# preset and the ability to set custom environment variables stay unchanged.
if ($Benchmark) {
    $env:VICTORY_AVX2_MERGE = '0'
    $env:VICTORY_WIDE_MERGE = '0'
    $env:VICTORY_WIDE_REFRESH = '0'
    $env:VICTORY_CARD_WINDOWS_MB = '0'
    $env:VICTORY_GPU_UPLOAD_SCRATCH = '0'
    $env:VICTORY_MAPPING_SHARDS = '0'
    $env:VICTORY_HEAP_PLAN_REUSE = '0'
    $env:VICTORY_PIPELINE_WAIT_SHARED = 'reserve'
    if ($Benchmark -in @('AVX2','Balanced','Combined')) { $env:VICTORY_AVX2_MERGE = '1' }
    if ($Benchmark -in @('WideMerge','Combined')) { $env:VICTORY_WIDE_MERGE = '1' }
    if ($Benchmark -in @('WideRefresh','Combined')) { $env:VICTORY_WIDE_REFRESH = '1' }
    if ($Benchmark -in @('CardWindows','Combined')) { $env:VICTORY_CARD_WINDOWS_MB = '1024' }
    if ($Benchmark -in @('ReBAR','Balanced','Combined')) { $env:VICTORY_GPU_UPLOAD_SCRATCH = '1' }
    if ($Benchmark -in @('MappingShards','Balanced','Combined')) { $env:VICTORY_MAPPING_SHARDS = '1' }
    if ($Benchmark -in @('HeapPlan','Balanced','Combined')) { $env:VICTORY_HEAP_PLAN_REUSE = '1' }
    if ($Benchmark -in @('PipelineWindow','Balanced','Combined')) { $env:VICTORY_PIPELINE_WAIT_SHARED = 'window' }
    # Balanced keeps the original VRAM limits and wide-copy settings;
    # Combined additionally tests the older wide and card-window switches.
    Write-Host "Benchmark mode: $Benchmark"
}
$console = if ($SeriesX) { 'series-x' } else { 'series-s' }

# Shader warm-up: without it every shader is translated and compiled while the game runs, behind a
# black screen (the loading screen included). Run once per build of victory.exe: on the first run
# and after every update or rebuild (a new exe can translate differently). Same settings as the
# game, so it fills the entries the game looks up. -NoWarm skips it; -Warm forces it.
$exeInfo = Get-Item $exe
$stamp = "$($exeInfo.Length)|$($exeInfo.LastWriteTimeUtc.Ticks)|$env:VICTORY_SHADER_LOOP_LIMIT"
$stampFile = Join-Path $root 'play.local.warm'
$warmed = (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)
if ($Warm -or (-not $NoWarm -and -not $warmed)) {
    $gameDir = Split-Path -Parent $Game
    Write-Host "Translating the game's shaders for this build (once per build; 5-15 min the first time)..."
    & $exe warm "$gameDir"
    if ($LASTEXITCODE -eq 0) {
        Set-Content -Path $stampFile -Value $stamp -Encoding utf8
    } else {
        Write-Warning "Shader warm-up failed (exit code $LASTEXITCODE); the game will translate shaders while it runs."
    }
}

$log = Join-Path $root ('logs\' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $log | Out-Null
if ($Benchmark) {
    $env:VICTORY_FRAMETIME_DUMP = Join-Path $log 'frametime.csv'
    "benchmark=$Benchmark" | Set-Content (Join-Path $log 'benchmark.txt') -Encoding utf8
    Get-ChildItem Env:VICTORY_* | Sort-Object Name | ForEach-Object {
        "$($_.Name)=$($_.Value)"
    } | Add-Content (Join-Path $log 'benchmark.txt') -Encoding utf8
    Write-Host "Frame timing CSV: $env:VICTORY_FRAMETIME_DUMP"
}
"victory $build | console $console | $([Environment]::OSVersion.VersionString) | game $Game" | Set-Content (Join-Path $log 'run.txt') -Encoding utf8
Write-Host "Log: $log\err.txt"
$p = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru `
    -ArgumentList 'run', "`"$Game`"", '--console', $console, '--execute' `
    -RedirectStandardError (Join-Path $log 'err.txt') -RedirectStandardOutput (Join-Path $log 'out.txt')
$p.WaitForExit()
"exit code $($p.ExitCode)" | Add-Content (Join-Path $log 'run.txt')
Write-Host "Game exited with code $($p.ExitCode). Log: $log\err.txt"
