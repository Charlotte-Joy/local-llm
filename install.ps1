# Installs Ollama (if needed) and three local coding models sized for this machine.
# Windows, PowerShell 5.1+. Usage: .\install.ps1 [--tier light,medium,heavy|all] [--budget GB] [--dry-run] [--yes] [--no-context]

$ModelsFile = Join-Path $PSScriptRoot 'models.txt'
$MinOllama  = [version]'0.14.0'
$Registry   = 'https://registry.ollama.ai/v2'
$Server     = 'http://localhost:11434'
# PowerShell 5.1 defaults to TLS 1.0, which ollama.com refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Say($m)  { Write-Host $m }
function Step($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "Warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }
function Ask($q, $default = 'N') { # with 'Y', pressing Enter means yes; --yes skips the question
  if ($Yes) { return $true }
  if ($default -eq 'Y') { $a = Read-Host "$q [Y/n]"; return ($a -eq '' -or $a -match '^(y|yes)$') }
  return ((Read-Host "$q [y/N]") -match '^(y|yes)$')
}
function Human($b) { '{0:N1} GB' -f ($b / 1e9) }

$Tier = 'all'; $BudgetOverride = $null; $DryRun = $false; $Yes = $false; $NoContext = $false
$argv = @($args)
for ($i = 0; $i -lt $argv.Count; $i++) {
  switch -Regex ($argv[$i]) {
    '^--?tier$'       { $i++; $Tier = "$($argv[$i])".ToLower() }
    '^--?budget$'     { $i++; $BudgetOverride = "$($argv[$i])" }
    '^--?dry-?run$'   { $DryRun = $true }
    '^(--?yes|-y)$'   { $Yes = $true }
    '^--?no-?context$' { $NoContext = $true }
    '^(--?help|-h|/\?)$' { Get-Content $PSCommandPath -TotalCount 3 | Select-Object -Skip 1 | ForEach-Object { $_.TrimStart('# ') }; exit 0 }
    default           { Die "Unknown option: $($argv[$i]) (try --help)" }
  }
}
$tierAliases = @{ all = 'light', 'medium', 'heavy'; light = 'light'; low = 'light'; medium = 'medium'; mid = 'medium'; heavy = 'heavy'; high = 'heavy' }
$want = @(); $badTier = $false
foreach ($t in ($Tier -split ',')) {
  $t = $t.Trim()
  if ($tierAliases.ContainsKey($t)) { $want += $tierAliases[$t] } else { $badTier = $true }
}
if ($badTier -or $want.Count -eq 0) { Die '--tier takes light, medium, heavy or all. Pick several with commas, e.g. --tier light,medium' }
if ($BudgetOverride -and $BudgetOverride -notmatch '^\d+(\.\d+)?$') { Die '--budget needs a number of GB, e.g. --budget 24' }
if ($env:OS -ne 'Windows_NT') { Die 'This script is for Windows. On macOS or Linux, run install.sh instead.' }
if (-not (Test-Path $ModelsFile)) { Die "Can't read $ModelsFile (it must sit next to this script)." }
if ($DryRun) { Say 'Dry run: nothing will be installed or changed.' }

# ---------------------------------------------------------------------------
# Step 1: detect hardware and work out the memory budget (GB a model can use)
# ---------------------------------------------------------------------------
Step 'Checking your hardware'
$RamGB = [int][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$HasGpu = $false
# NVIDIA: nvidia-smi ships with the driver. It reports each card's VRAM in MiB; use the largest card.
$nvMiB = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  $nvMiB = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null |
    Where-Object { $_ -match '^\s*\d+\s*$' } | ForEach-Object { [int]$_ } | Sort-Object | Select-Object -Last 1
}
if ($nvMiB) {
  $HasGpu = $true; $Budget = [int][math]::Round($nvMiB / 1024)
  $Hw = "NVIDIA GPU with ${Budget}GB VRAM (${RamGB}GB system RAM)"
} else {
  # AMD/Intel: WMI's AdapterRAM is a 32-bit field that tops out at 4GB, so read the driver's 64-bit
  # HardwareInformation.qwMemorySize from the display-adapter class key (one 0000, 0001... subkey per adapter).
  $classKey = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  $bestBytes = 0; $bestName = ''
  foreach ($key in Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }) {
    $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
    $bytes = $props.'HardwareInformation.qwMemorySize'
    if ($bytes -is [byte[]]) { $bytes = [BitConverter]::ToUInt64($bytes + [byte[]]::new(8), 0) }  # some drivers store it as binary
    if ($bytes -and [uint64]$bytes -gt $bestBytes) { $bestBytes = [uint64]$bytes; $bestName = $props.DriverDesc }
  }
  # Integrated graphics usually report a small carve-out; under 2GB is treated as no usable GPU.
  if ($bestBytes -ge 2GB) {
    $HasGpu = $true; $Budget = [int][math]::Round($bestBytes / 1GB)
    $Hw = "$bestName with ${Budget}GB VRAM (${RamGB}GB system RAM)"
  } else {
    $Budget = [int][math]::Floor($RamGB / 2); $Hw = "no supported GPU found, ${RamGB}GB RAM"
  }
}
Say "Detected: $Hw"
if (-not $HasGpu) { Warn 'No usable GPU, so models will run on the CPU. Expect slow answers.' }
if ($BudgetOverride) {
  Say "Memory budget: ${Budget}GB detected, using your override of $([int][math]::Floor([double]$BudgetOverride))GB"
  $Budget = [int][math]::Floor([double]$BudgetOverride)
} else { Say "Memory budget: ${Budget}GB (override with --budget <GB>)" }

# ---------------------------------------------------------------------------
# Step 2: pick the tier row from models.txt and check each tag exists
# ---------------------------------------------------------------------------
Step 'Choosing models'
$rows = foreach ($line in Get-Content $ModelsFile) {
  $cells = ($line -replace '#.*', '').Trim() -split '\s+'
  if ($cells.Count -ge 4 -and $cells[0] -match '^\d+$') {
    [pscustomobject]@{ Min = [int]$cells[0]; Specs = @($cells[1], $cells[2], $cells[3]) }
  }
}
$fits = @($rows | Where-Object { $_.Min -le $Budget } | Sort-Object Min)
if ($fits.Count -eq 0) { Die "No row in models.txt fits a ${Budget}GB budget." }
$row = $fits[-1]
if (-not $HasGpu -and -not $BudgetOverride -and $row.Min -ge 16 -and $fits.Count -gt 1) {
  Warn "Without a GPU the $($row.Min)GB row would be painfully slow, so using the $($fits[-2].Min)GB row instead."
  $row = $fits[-2]
}
Say "Using the $($row.Min)GB+ row of models.txt"

function Get-ManifestSize($tag) { # -> 'missing', 'unknown', or total download bytes
  $name, $ver = $tag -split ':', 2
  if (-not $ver) { $ver = 'latest' }
  if ($name -notmatch '/') { $name = "library/$name" }
  try {
    $m = Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 -Uri "$Registry/$name/manifests/$ver" `
           -Headers @{ Accept = 'application/vnd.docker.distribution.manifest.v2+json' }
    if ($m -is [string]) { $m = $m | ConvertFrom-Json }
    return [int64](($m.layers | Measure-Object size -Sum).Sum + $m.config.size)
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 404) { return 'missing' }
    return 'unknown'
  }
}
$tierNames = 'light', 'medium', 'heavy'
$plan = @(); $missing = @()
foreach ($n in 0..2) {   # O(tiers x fallbacks): a handful of registry lookups
  if ($want -notcontains $tierNames[$n]) { continue }
  $alts = $row.Specs[$n] -split '\|'
  $pick = $null
  foreach ($alt in $alts) {
    $size = Get-ManifestSize $alt
    if ($size -eq 'unknown') { $pick = @{ Tag = $alts[0]; Size = 0; Note = "couldn't reach ollama.com to check this tag; will try anyway" }; break }
    if ($size -ne 'missing') {
      $note = ''; if ($alt -ne $alts[0]) { $note = "$($alts[0]) is not published, falling back to $alt" }
      $pick = @{ Tag = $alt; Size = $size; Note = $note }; break
    }
  }
  if (-not $pick) { Warn "$($tierNames[$n]): '$($alts -join ' or ')' was not found on ollama.com (renamed? edit models.txt)"; $missing += $tierNames[$n]; continue }
  $plan += [pscustomobject]@{ Tier = $tierNames[$n]; Tag = $pick.Tag; Size = $pick.Size; Note = $pick.Note }
}
if ($plan.Count -eq 0) { Die 'None of the chosen models could be found. Check the tags in models.txt.' }

# ---------------------------------------------------------------------------
# Step 3: make sure Ollama is installed, new enough and running
# ---------------------------------------------------------------------------
Step 'Checking Ollama'
function Find-Ollama {
  $cmd = Get-Command ollama -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $default = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
  if (Test-Path $default) { return $default }
  return $null
}
function Get-OllamaVersion($exe) {
  $found = [regex]::Matches((& $exe --version 2>&1 | Out-String), '\d+\.\d+\.\d+')
  if ($found.Count) { return [version]$found[$found.Count - 1].Value }
  return $null
}
function Install-Ollama($verb) { # Install | Update
  $target = ''; if ($latest) { $target = " to $latest" }
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    if (-not (Ask "$verb Ollama$target with winget?" 'Y')) { return $false }
    $action = 'install'; if ($verb -eq 'Update') { $action = 'upgrade' }
    $wingetArgs = @($action, '--id', 'Ollama.Ollama', '-e')
    if ($Yes) { $wingetArgs += '--accept-package-agreements', '--accept-source-agreements' }
    & winget @wingetArgs
  } else {
    if (-not (Ask "$verb Ollama$target with the official installer from ollama.com?" 'Y')) { return $false }
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    $ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1's progress bar slows big downloads to a crawl
    Say 'Downloading the Ollama installer...'
    try { Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup }
    catch { Warn "Download failed: $($_.Exception.Message)"; return $false }
    if ((Get-AuthenticodeSignature $setup).Status -ne 'Valid') { Warn "The installer isn't validly signed, so it was not run."; return $false }
    Start-Process $setup -Wait
  }
  # Installers change PATH for new windows only; refresh it for this one.
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  return $true
}
try { $latest = [version]((Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Uri 'https://api.github.com/repos/ollama/ollama/releases/latest').tag_name.TrimStart('v')) }
catch { $latest = $null; Warn "Couldn't look up the latest Ollama version (offline?), so it won't be updated." }
$ollama = Find-Ollama
if (-not $ollama) {
  Say 'Ollama is not installed.'
  if ($DryRun) { Say "(dry run) Would install Ollama $latest now." }
  else {
    if (-not (Install-Ollama 'Install')) { Die 'Ollama is required. Install it from https://ollama.com/download, then re-run this script.' }
    $ollama = Find-Ollama
    if (-not $ollama) { Die "Ollama was installed but can't be found yet. Open a new PowerShell window and re-run." }
  }
}
if ($ollama) {
  $ver = Get-OllamaVersion $ollama
  if ($latest -and $ver -and $ver -lt $latest) {
    Say "Ollama $ver is installed; the latest is $latest."
    if ($DryRun) { Say "(dry run) Would update Ollama to $latest." }
    elseif (Install-Ollama 'Update') { $ollama = Find-Ollama; $ver = Get-OllamaVersion $ollama }
    else { Warn "Keeping Ollama $ver. Newer models may refuse to download." }
  }
  if ($ver -and $ver -ge $MinOllama) { Ok "Ollama $ver" }
  elseif ($DryRun) { Warn "Ollama $ver is older than $MinOllama, which Claude Code needs." }
  else { Die "Ollama $ver is older than $MinOllama, which Claude Code needs. Update it, then re-run." }
}

function Test-Server { try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri $Server); return $true } catch { return $false } }
if (-not $DryRun -and -not (Test-Server)) {
  Say 'Starting the Ollama server...'
  $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
  if (Test-Path $app) { Start-Process $app } else { Start-Process $ollama -ArgumentList 'serve' -WindowStyle Hidden }
  foreach ($s in 1..30) { if (Test-Server) { break }; Start-Sleep 1 }
  if (-not (Test-Server)) { Die "The Ollama server didn't start within 30 seconds. Try running 'ollama serve' yourself." }
}
$installed = @()
if ($ollama -and (Test-Server)) {
  Ok 'Ollama server is running'
  $installed = @(& $ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
}
# After an update, a server started earlier may still be the old version, and new models would be refused.
function Get-ServerVersion { try { return [version](Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri "$Server/api/version").version } catch { return $null } }
$serverVer = Get-ServerVersion
if ($serverVer -and $ver -and $serverVer -ne $ver) {
  if ($DryRun) { Warn "The running Ollama server is version $serverVer, not $ver. A real run would restart it." }
  else {
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    if ((Test-Path $app) -and (Ask "The running Ollama server is still $serverVer. Restart Ollama so it uses $ver?" 'Y')) {
      Get-Process 'ollama app', 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force
      Start-Sleep 2; Start-Process $app
      foreach ($s in 1..30) { if ((Get-ServerVersion) -eq $ver) { break }; Start-Sleep 1 }
    }
    $serverVer = Get-ServerVersion
    if ($serverVer -ne $ver) { Die "The running Ollama server is version $serverVer, not $ver. Quit Ollama from the system tray, start it again, then re-run this script." }
    Ok "Ollama server restarted on $ver"
  }
}
function Test-Installed($tag) { return ($installed -contains $tag) -or ($installed -contains "${tag}:latest") }

# ---------------------------------------------------------------------------
# Step 4: summary, disk check, confirm, download
# ---------------------------------------------------------------------------
Step 'Plan'
$modelsDir = $env:OLLAMA_MODELS
if (-not $modelsDir) { $modelsDir = Join-Path $HOME '.ollama\models' }
$root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($modelsDir))
$free = [IO.DriveInfo]::new($root).AvailableFreeSpace
Say "Hardware: $Hw"
Say "Budget:   ${Budget}GB"
for ($i = 0; $i -lt $plan.Count; $i++) {
  $p = $plan[$i]
  if (Test-Installed $p.Tag) { $status = 'already installed' }
  elseif ($p.Size -gt 0) { $status = "$(Human $p.Size) download" }
  else { $status = 'download size unknown' }
  Say ('  {0,-7} {1,-28} {2}' -f $p.Tier, $p.Tag, $status)
  if ($p.Note) { Say "          ($($p.Note))" }
}

$total = [int64]0; $todo = @()
foreach ($p in $plan) {
  if ((Test-Installed $p.Tag) -or ($todo -contains $p.Tag)) { continue }
  $todo += $p.Tag; $total += $p.Size
}
Say "To download: $($todo.Count) model(s), $(Human $total)   Free disk space: $(Human $free) (on $root)"
$need = $total + 10 * 1e9
if ($todo.Count -gt 0 -and $free -lt $need) {
  if ($DryRun) { Warn "Not enough disk space: need $(Human $need) free (downloads + 10 GB headroom). A real run would stop here."; exit 1 }
  Die "Not enough disk space: need $(Human $need) free (downloads + 10 GB headroom). Free up space or pick fewer with --tier."
}
$ctx = 32768; if ($Budget -ge 28) { $ctx = 65536 }
if ($DryRun) {
  if (-not $NoContext) { Say "Would set OLLAMA_CONTEXT_LENGTH=$ctx." }
  Say 'Dry run finished. Run without --dry-run to install.'; exit 0
}
$failed = @()
if ($todo.Count -gt 0) {
  if (-not (Ask "Download $($todo.Count) model(s), $(Human $total) in total?" 'Y')) { Die 'Cancelled. Nothing was downloaded.' }
  foreach ($t in $todo) {
    Step "Downloading $t"
    & $ollama pull $t
    if ($LASTEXITCODE -ne 0) { $failed += $t; Warn "Download of $t failed; carrying on." }
  }
} else { Ok 'All of these models are already installed.' }

# ---------------------------------------------------------------------------
# Step 5: raise Ollama's context window so coding agents can see enough code
# ---------------------------------------------------------------------------
if (-not $NoContext) {
  Step 'Context window'
  if ([Environment]::GetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', 'User') -eq "$ctx") { Ok "OLLAMA_CONTEXT_LENGTH is already $ctx" }
  elseif (Ask "Set Ollama's context window to $ctx tokens (default 4096 is too small for coding agents)?") {
    setx OLLAMA_CONTEXT_LENGTH $ctx | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "Set. Quit Ollama from the system tray and start it again to apply." }
    else { Warn "Couldn't set it. Run: setx OLLAMA_CONTEXT_LENGTH $ctx" }
  }
}

# ---------------------------------------------------------------------------
# Step 6: what's installed and how to use it
# ---------------------------------------------------------------------------
Step 'All done'
$uses = @{
  light  = 'quick questions, explanations and autocomplete (fastest)'
  medium = 'everyday coding: writing functions, fixing bugs, reviews'
  heavy  = 'hard problems, big refactors and agent work (slowest, smartest)'
}
$first = $null
foreach ($p in $plan) {
  if ($failed -contains $p.Tag) { continue }
  $use = $uses[$p.Tier]
  if (Test-Installed $p.Tag) { $use += ' [already had it]' }
  Say ('  {0,-7} {1,-28} {2}' -f $p.Tier, $p.Tag, $use)
  if (-not $first) { $first = $p.Tag }
}
if (-not $first) { Say '  No models were installed this time.' }
Say ''
if ($first) { Say "Try a model:          ollama run $first" }
if (Get-Command claude -ErrorAction SilentlyContinue) { Say 'Claude Code is installed on this machine, so you can use these models with it.' }
Say 'Use with Claude Code: ollama launch claude   (then pick a model)'
Say 'Remove a model:       ollama rm <model>'
if ($missing.Count) { Warn "Skipped because the tag wasn't found: $($missing -join ', ')" }
if ($failed.Count -and $latest -and $ver -and $ver -lt $latest) { Warn "Your Ollama ($ver) is older than the latest ($latest), and new models often need it. Re-run this script and accept the Ollama update." }
if ($failed.Count) { Warn "These downloads failed: $($failed -join ', '). Re-run this script to retry."; exit 1 }
exit 0
