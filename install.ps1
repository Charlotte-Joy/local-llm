# Installs Ollama (if needed) and three local coding models sized for this machine.
# Windows, PowerShell 5.1+. Usage: .\install.ps1 [--tier light|medium|heavy|all] [--budget GB] [--dry-run] [--yes] [--no-context]

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
function Ask($q)  { if ($Yes) { return $true }; return ((Read-Host "$q [y/N]") -match '^(y|yes)$') }
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
if ($Tier -notin 'light', 'medium', 'heavy', 'all') { Die '--tier must be light, medium, heavy or all' }
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
  if ($Tier -ne 'all' -and $Tier -ne $tierNames[$n]) { continue }
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
function Install-Ollama($verb) { # install | upgrade
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say 'Please download Ollama from https://ollama.com/download, run the installer, then re-run this script.'
    return $false
  }
  if (-not (Ask "$verb Ollama with winget (winget $verb Ollama.Ollama)?")) { return $false }
  $wingetArgs = @($verb, '--id', 'Ollama.Ollama', '-e')
  if ($Yes) { $wingetArgs += '--accept-package-agreements', '--accept-source-agreements' }
  & winget @wingetArgs
  # winget changes PATH for new windows only; refresh it for this one.
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  return $true
}
$ollama = Find-Ollama
if (-not $ollama) {
  Say 'Ollama is not installed.'
  if ($DryRun) { Say '(dry run) Would install Ollama now.' }
  else {
    if (-not (Install-Ollama 'install')) { Die 'Ollama is required. Install it, then re-run this script.' }
    $ollama = Find-Ollama
    if (-not $ollama) { Die "Ollama still can't be found. Open a new PowerShell window and re-run." }
  }
}
if ($ollama) {
  $ver = Get-OllamaVersion $ollama
  if ($ver -and $ver -ge $MinOllama) { Ok "Ollama $ver" }
  else {
    Warn "Ollama $ver is older than $MinOllama, which Claude Code needs."
    if ($DryRun) { Say '(dry run) Would offer to upgrade.' }
    else {
      [void](Install-Ollama 'upgrade'); $ver = Get-OllamaVersion $ollama
      if (-not $ver -or $ver -lt $MinOllama) { Die "Please upgrade Ollama to $MinOllama or newer, then re-run." }
      Ok "Ollama $ver"
    }
  }
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
  Say ('  {0}) {1,-7} {2,-28} {3}' -f ($i + 1), $p.Tier, $p.Tag, $status)
  if ($p.Note) { Say "             ($($p.Note))" }
}

# Let the user pick which of the models to get. --yes, --tier and --dry-run keep the whole plan.
$chosen = @($plan); $picked = $false
if (-not $DryRun -and -not $Yes -and $Tier -eq 'all' -and $plan.Count -gt 1) {
  $picked = $true
  while ($true) {
    $answer = (Read-Host 'Which models do you want? Type numbers (e.g. "1 3"), press Enter for all, or "n" for none').Trim()
    if ($answer -eq '') { break }
    if ($answer -match '^(n|no|none)$') { $chosen = @(); break }
    $nums = @($answer -split '[\s,]+')
    $bad = @($nums | Where-Object { $_ -notmatch '^\d+$' -or [int]$_ -lt 1 -or [int]$_ -gt $plan.Count })
    if ($bad.Count -eq 0) { $chosen = @($nums | ForEach-Object { $plan[[int]$_ - 1] }); break }
    Warn "Please type numbers between 1 and $($plan.Count), separated by spaces."
  }
}
$total = [int64]0; $todo = @()
foreach ($p in $chosen) {
  if ((Test-Installed $p.Tag) -or ($todo -contains $p.Tag)) { continue }
  $todo += $p.Tag; $total += $p.Size
}
Say "To download: $($todo.Count) model(s), $(Human $total)   Free disk space: $(Human $free) (on $root)"
$need = $total + 10 * 1e9
if ($todo.Count -gt 0 -and $free -lt $need) {
  if ($DryRun) { Warn "Not enough disk space: need $(Human $need) free (downloads + 10 GB headroom). A real run would stop here."; exit 1 }
  Die "Not enough disk space: need $(Human $need) free (downloads + 10 GB headroom). Free up space or pick fewer models."
}
$ctx = 32768; if ($Budget -ge 28) { $ctx = 65536 }
if ($DryRun) {
  if (-not $NoContext) { Say "Would set OLLAMA_CONTEXT_LENGTH=$ctx." }
  Say 'Dry run finished. Run without --dry-run to install.'; exit 0
}
$failed = @()
if ($todo.Count -gt 0) {
  if (-not $picked -and -not (Ask "Download $($todo.Count) model(s) now?")) { Die 'Cancelled. Nothing was downloaded.' }
  foreach ($t in $todo) {
    Step "Downloading $t"
    & $ollama pull $t
    if ($LASTEXITCODE -ne 0) { $failed += $t; Warn "Download of $t failed; carrying on." }
  }
} elseif ($chosen.Count) { Ok 'The models you chose are already installed.' }
else { Say 'No models chosen, so nothing to download.' }

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
foreach ($p in $chosen) {
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
if ($failed.Count) {
  # A pull fails with "requires a newer version of Ollama" when a model needs a newer release than this one.
  try { $latest = [version]((Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Uri 'https://api.github.com/repos/ollama/ollama/releases/latest').tag_name.TrimStart('v')) } catch { $latest = $null }
  if ($latest -and $ver -and $ver -lt $latest) { Warn "Your Ollama ($ver) is older than the latest ($latest), and new models often need it. Update with: winget upgrade Ollama.Ollama" }
}
if ($failed.Count) { Warn "These downloads failed: $($failed -join ', '). Re-run this script to retry."; exit 1 }
exit 0
