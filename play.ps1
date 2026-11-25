# Starts the game with the recommended settings and writes a log for every run.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\play.ps1 -Game "D:\Games\GTA VI\game_scarlett_master.exe"
#
# The game path is remembered in play.local.txt (not committed), so later runs need no argument.
# Each run writes logs\<date_time>\err.txt (the runtime's log) and out.txt. Share err.txt when reporting a crash.
param(
    [string]$Game = '',
    [switch]$Release,            # use target\release instead of target\diag
    [switch]$Perf,               # use target\perf (ThinLTO performance build)
    [switch]$FSR,                # optional PC FidelityFX SDK upscaler
    [switch]$NoFSR,              # restore original linear upscale
    [switch]$NoIndirectWindow,   # diagnose missing geometry with per-record clamping
    [switch]$GeometrySafe,       # diagnostic: longer, shared pipeline waits to preserve one-shot geometry
    [switch]$HeapSync,           # experimental: mirror raw CPU descriptor copies
    [switch]$AlignedViews,       # experimental: aligned copies for structured SRVs
    [switch]$DescriptorData,     # experimental: translate size-only buffer descriptors
    [ValidateRange(1,120)]
    [int]$TextureHashEvery = 8,  # guarded texture fallback hash cadence in frames
    [ValidateRange(0,512)]
    [int]$MeshPrewarm = 0,       # speculative mesh pipeline budget per run
    [ValidateRange(-1,4)]
    [double]$Ambient = -1,      # experimental ambient light; -1 disables
    [ValidateRange(50,97)]
    [int]$TextureRoomPercent = 90, # DXGI budget share for background textures
    [ValidateRange(0,8192)]
    [int]$TargetReserveMB = 0,  # reserve for render targets not yet allocated
    [ValidateScript({ $_ -eq 0 -or ($_ -ge 50 -and $_ -le 97) })]
    [int]$VramEvictPercent = 0, # pressure-based idle texture eviction; 0 disables
    [ValidateRange(0,1024)]
    [int]$StorageScratchKB = 0, # retained KiB per DirectStorage scratch buffer
    [ValidateRange(0,64)]
    [int]$StorageWorkers = 0,   # DirectStorage worker count; 0 uses available parallelism
    [string]$FsrDir = '',        # SDK signedbin directory
    [switch]$SeriesX,            # run as the larger console (about half the frame rate of the default Series S mode)
    [switch]$NoWarm,             # skip the shader warm-up even if this build has not done it
    [switch]$Warm,               # redo the shader warm-up even if this build already did it
    [ValidateSet('Baseline','AVX2','WideMerge','WideRefresh','CardWindows','ReBAR','MappingShards','HeapPlan','PipelineWindow','TextureIdle','TextureQueue','RyzenWorkers','SmallBuffers','ChangedRuns','ResidentTextures','Balanced','Combined')]
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

if ($Release -and $Perf) { throw 'Choose either -Release or -Perf.' }
if ($GeometrySafe -and $Benchmark) { throw 'Choose -GeometrySafe or -Benchmark for an isolated test.' }
$build = if ($Perf) { 'perf' } elseif ($Release) { 'release' } else { 'diag' }
$exe = Join-Path $root "target\$build\victory.exe"
if (-not (Test-Path $exe)) {
    $command = if ($Perf) { 'cargo build --locked --profile perf -p victory' } elseif ($Release) { 'cargo build --locked --release -p victory' } else { 'cargo build --locked --profile diag -p victory --features diagnostics' }
    throw "Not built yet: $exe. Build first: $command"
}

# Recommended preset (shadowdog00's, tested on an RTX 5060 Ti and an RX 6700 XT 12 GB).
# Cache and saves default to %LOCALAPPDATA%\victory.
$env:VICTORY_DISPLAY_MODE        = '1280x720'   # indoor walls draw with this
$env:VICTORY_SHADER_LOOP_LIMIT   = '256'        # without it the GPU hangs in the open world
$env:VICTORY_RELAY               = '2'
$env:VICTORY_INDIRECT_WINDOW     = if ($NoIndirectWindow) { '0' } else { '1' }
$env:VICTORY_HEAP_SYNC           = if ($HeapSync) { '1' } else { '0' }
if ($HeapSync) { Write-Host 'HeapSync: experimental raw descriptor synchronization.' }
$env:VICTORY_ALIGNED_VIEWS = if ($AlignedViews) { '1' } else { '0' }
if ($AlignedViews) { Write-Host 'AlignedViews: experimental structured SRV copies.' }
$env:VICTORY_TEXTURE_HASH_EVERY = [string]$TextureHashEvery
$env:VICTORY_TEXTURE_ROOM_PERCENT = [string]$TextureRoomPercent
$env:VICTORY_CARD_ROOM_FOR_TARGETS_MB = [string]$TargetReserveMB
$env:VICTORY_VRAM_EVICT = [string]$VramEvictPercent
$env:VICTORY_DSTORAGE_SCRATCH_KB = [string]$StorageScratchKB
$env:VICTORY_DSTORAGE_WORKERS = [string]$StorageWorkers
if ($StorageWorkers -gt 0) { Write-Host "DirectStorage workers: $StorageWorkers." }
if ($StorageScratchKB -gt 0) { Write-Host "DirectStorage scratch retention: $StorageScratchKB KiB per buffer." }
if ($VramEvictPercent -gt 0) { Write-Host "VRAM eviction: above $VramEvictPercent percent." }
if ($TextureRoomPercent -ne 90 -or $TargetReserveMB -gt 0) {
    Write-Host "VRAM policy: $TextureRoomPercent percent, $TargetReserveMB MiB target reserve."
}
$env:VICTORY_AMBIENT = if ($Ambient -ge 0) { $Ambient.ToString([System.Globalization.CultureInfo]::InvariantCulture) } else { 'off' }
if ($Ambient -ge 0) { Write-Host "Ambient: experimental diffuse light $env:VICTORY_AMBIENT." }
$env:VICTORY_MESH_PREWARM = [string]$MeshPrewarm
if ($MeshPrewarm -gt 0) { Write-Host "MeshPrewarm: up to $MeshPrewarm speculative pipelines." }
$env:VICTORY_DESC_DATA = if ($DescriptorData) { '1' } else { '0' }
if ($DescriptorData) { Write-Host 'DescriptorData: experimental size-only buffer translation.' }
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
    $env:VICTORY_ADAPTIVE_TEXTURE_IDLE = '0'
    $env:VICTORY_CHANGED_RUNS = '0'
    Remove-Item Env:VICTORY_CARD_BUFFERS_MIN_KB -ErrorAction SilentlyContinue
    foreach ($key in @('VICTORY_WIDE_THREADS','VICTORY_TEXTURE_THREADS','VICTORY_TEXTURE_QUEUE_MB','VICTORY_TEXTURE_QUEUE_MS')) {
        Remove-Item "Env:$key" -ErrorAction SilentlyContinue
    }
    if ($Benchmark -in @('AVX2','Balanced','Combined')) { $env:VICTORY_AVX2_MERGE = '1' }
    if ($Benchmark -in @('WideMerge','Combined')) { $env:VICTORY_WIDE_MERGE = '1' }
    if ($Benchmark -in @('WideRefresh','Combined')) { $env:VICTORY_WIDE_REFRESH = '1' }
    if ($Benchmark -in @('CardWindows','Combined')) { $env:VICTORY_CARD_WINDOWS_MB = '1024' }
    if ($Benchmark -in @('ReBAR','Balanced','Combined')) { $env:VICTORY_GPU_UPLOAD_SCRATCH = '1' }
    if ($Benchmark -in @('MappingShards','Balanced','Combined')) { $env:VICTORY_MAPPING_SHARDS = '1' }
    if ($Benchmark -in @('HeapPlan','Balanced','Combined')) { $env:VICTORY_HEAP_PLAN_REUSE = '1' }
    if ($Benchmark -in @('PipelineWindow','Balanced','Combined')) { $env:VICTORY_PIPELINE_WAIT_SHARED = 'window' }
    if ($Benchmark -in @('TextureIdle','Combined')) { $env:VICTORY_ADAPTIVE_TEXTURE_IDLE = '1' }
    if ($Benchmark -in @('TextureQueue','Combined')) {
        $env:VICTORY_TEXTURE_QUEUE_MB = '256'
        $env:VICTORY_TEXTURE_QUEUE_MS = '100'
    }
    if ($Benchmark -in @('RyzenWorkers','Combined')) {
        $env:VICTORY_WIDE_THREADS = '6'
        $env:VICTORY_TEXTURE_THREADS = '4'
    }
    if ($Benchmark -eq 'SmallBuffers') { $env:VICTORY_CARD_BUFFERS_MIN_KB = '64' }
    if ($Benchmark -eq 'ChangedRuns') { $env:VICTORY_CHANGED_RUNS = '1' }
    if ($Benchmark -eq 'ResidentTextures') { $env:VICTORY_REUPLOAD_WHEN_FULL = '1' }
    # Balanced keeps the original VRAM limits and wide-copy settings;
    # Combined additionally tests the older wide and card-window switches.
    Write-Host "Benchmark mode: $Benchmark"
}
if ($GeometrySafe) {
    # Keep the rest of the normal preset. A 10 s base disables the old
    # 3 s graphics / 10 s compute cutoff; the existing loading allowance
    # can raise compute to 12 s. Window sharing avoids dropping another
    # recording thread's pipeline merely because a thread is waiting.
    $env:VICTORY_PIPELINE_WAIT_MS = '10000'
    $env:VICTORY_PIPELINE_WAIT_SHARED = 'window'
    Write-Host 'GeometrySafe: longer pipeline waits; expect loading stalls.'
}
$console = if ($SeriesX) { 'series-x' } else { 'series-s' }

# FSR is independent of the benchmark profile.
if ($NoFSR -and ($FSR -or $FsrDir)) { throw 'Choose -FSR or -NoFSR.' }
if ($NoFSR) {
    Remove-Item Env:VICTORY_FFX_DIR -ErrorAction SilentlyContinue
} elseif ($FSR -or $FsrDir) {
    if (-not $FsrDir) { $FsrDir = $env:VICTORY_FFX_DIR }
    if (-not $FsrDir) { $FsrDir = 'C:\FidelityFX-SDK\Kits\FidelityFX\signedbin' }
    foreach ($dll in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_upscaler_dx12.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $FsrDir $dll) -PathType Leaf)) {
            throw "Missing SDK library $dll in $FsrDir. Extract the official FidelityFX SDK 2.4.0 or use -NoFSR."
        }
    }
    $env:VICTORY_FFX_DIR = (Resolve-Path -LiteralPath $FsrDir).ProviderPath
    Write-Host "Experimental FSR: $env:VICTORY_FFX_DIR"
}


# Shader warm-up: without it every shader is translated and compiled while the game runs, behind a
# black screen (the loading screen included). Run once per build of victory.exe: on the first run
# and after every update or rebuild (a new exe can translate differently). Same settings as the
# game, so it fills the entries the game looks up. -NoWarm skips it; -Warm forces it.
$exeInfo = Get-Item $exe
$stamp = "$($exeInfo.Length)|$($exeInfo.LastWriteTimeUtc.Ticks)|$env:VICTORY_SHADER_LOOP_LIMIT|$env:VICTORY_DESC_DATA"
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
if ($Benchmark -or $GeometrySafe -or $HeapSync -or $AlignedViews -or $DescriptorData -or $TextureHashEvery -ne 8 -or $MeshPrewarm -gt 0 -or $Ambient -ge 0 -or $TextureRoomPercent -ne 90 -or $TargetReserveMB -gt 0 -or $VramEvictPercent -gt 0 -or $StorageScratchKB -gt 0 -or $StorageWorkers -gt 0) {
    $env:VICTORY_FRAMETIME_DUMP = Join-Path $log 'frametime.csv'
    $mode = if ($GeometrySafe) { 'GeometrySafe' } elseif ($Benchmark) { $Benchmark } elseif ($HeapSync) { 'HeapSync' } elseif ($AlignedViews) { 'AlignedViews' } elseif ($DescriptorData) { 'DescriptorData' } elseif ($TextureHashEvery -ne 8) { "TextureHash$TextureHashEvery" } elseif ($MeshPrewarm -gt 0) { "MeshPrewarm$MeshPrewarm" } elseif ($Ambient -ge 0) { 'Ambient' } elseif ($TextureRoomPercent -ne 90 -or $TargetReserveMB -gt 0 -or $VramEvictPercent -gt 0) { 'VRAM' } elseif ($StorageScratchKB -gt 0) { 'StorageScratch' } else { "StorageWorkers$StorageWorkers" }
    if ($HeapSync -and $mode -ne 'HeapSync') { $mode += '+HeapSync' }
    if ($AlignedViews -and $mode -ne 'AlignedViews') { $mode += '+AlignedViews' }
    if ($DescriptorData -and $mode -ne 'DescriptorData') { $mode += '+DescriptorData' }
    if ($TextureHashEvery -ne 8 -and $mode -ne "TextureHash$TextureHashEvery") { $mode += "+TextureHash$TextureHashEvery" }
    if ($MeshPrewarm -gt 0 -and $mode -ne "MeshPrewarm$MeshPrewarm") { $mode += "+MeshPrewarm$MeshPrewarm" }
    if ($Ambient -ge 0 -and $mode -ne 'Ambient') { $mode += '+Ambient' }
    if (($TextureRoomPercent -ne 90 -or $TargetReserveMB -gt 0 -or $VramEvictPercent -gt 0) -and $mode -ne 'VRAM') { $mode += '+VRAM' }
    if ($StorageScratchKB -gt 0 -and $mode -ne 'StorageScratch') { $mode += '+StorageScratch' }
    if ($StorageWorkers -gt 0 -and $mode -ne "StorageWorkers$StorageWorkers") { $mode += "+StorageWorkers$StorageWorkers" }
    "benchmark=$mode" | Set-Content (Join-Path $log 'benchmark.txt') -Encoding utf8
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
