# Launches one of your local models: pick light, medium or heavy with the arrow keys, then press Enter.
# Coding models open in Claude Code; writing and vision models open as a chat in this window.
# Windows, PowerShell 5.1+. Usage: .\launch.ps1 [--claude|--chat]

$StateFile = Join-Path $HOME '.local-llm\installed.txt'   # written by install.ps1: "use tier model" per line
$Server    = 'http://localhost:11434'
$ProgressPreference = 'SilentlyContinue'   # stops web requests drawing a progress bar over the menu

function Say($m) { Write-Host $m }
function Die($m) { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

$Mode = $null
foreach ($arg in $args) {
  switch -Regex ($arg) {
    '^--?claude$'        { $Mode = 'claude'; break }
    '^--?chat$'          { $Mode = 'chat'; break }
    '^(--?help|-h|/\?)$' { Get-Content $PSCommandPath -TotalCount 4 | Select-Object -Skip 1 | ForEach-Object { $_.TrimStart('# ') }; exit 0 }
    default              { Die "Unknown option: $arg (try --help)" }
  }
}

$ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
$appExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
if (-not $ollama -and (Test-Path $appExe)) { $ollama = $appExe }
if (-not $ollama) { Die "Ollama isn't installed. Run install.ps1 first." }

function Test-Server { try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri $Server); return $true } catch { return $false } }
if (-not (Test-Server)) {
  Say 'Starting Ollama...'
  $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
  if (Test-Path $app) { Start-Process $app } else { Start-Process $ollama -ArgumentList 'serve' -WindowStyle Hidden }
  foreach ($s in 1..30) { if (Test-Server) { break }; Start-Sleep 1 }
  if (-not (Test-Server)) { Die "Ollama didn't start within 30 seconds. Try running 'ollama serve' yourself." }
}

$installed = @(& $ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
if ($installed.Count -eq 0) { Die "You don't have any models yet. Run install.ps1 first." }

# Menu entries: the models install.ps1 set up (by use, then light/medium/heavy), or every installed
# model if the installer hasn't recorded any.
$entries = @()
if (Test-Path $StateFile) {
  $tierOrder = @{ light = 1; medium = 2; heavy = 3 }
  $hints = @{ light = 'fastest'; medium = 'balanced'; heavy = 'best quality, slowest' }
  $records = @(foreach ($line in Get-Content $StateFile) {
    $f = $line.Trim() -split '\s+'
    if ($f.Count -ge 3 -and $installed -contains $f[2]) { [pscustomobject]@{ Use = $f[0]; Tier = $f[1]; Tag = $f[2]; Order = $tierOrder[$f[1]] } }
  })
  $useCount = @($records | Select-Object -ExpandProperty Use -Unique).Count
  foreach ($r in ($records | Sort-Object Use, Order)) {
    $label = $r.Tier; if ($useCount -gt 1) { $label = "$($r.Use) $($r.Tier)" }
    $entries += [pscustomobject]@{ Tag = $r.Tag; Use = $r.Use; Text = ('{0,-15} {1,-26} {2}' -f $label, $r.Tag, $hints[$r.Tier]) }
  }
}
if ($entries.Count -eq 0) { $entries = @($installed | ForEach-Object { [pscustomobject]@{ Tag = $_; Use = ''; Text = $_ } }) }

function Show-Menu($items) { # arrow keys move, Enter picks; returns the selected index
  Write-Host 'Which model? ' -NoNewline; Write-Host '(arrow keys to move, Enter to start)' -ForegroundColor DarkGray
  # Print the blank lines first so the window has scrolled before we remember where the menu starts.
  foreach ($i in 1..$items.Count) { Write-Host '' }
  $top = [Math]::Max(0, [Console]::CursorTop - $items.Count)   # some terminals can't report the cursor row
  $width = [Math]::Max([Console]::WindowWidth - 1, 20)
  $sel = 0
  [Console]::CursorVisible = $false
  try {
    while ($true) {
      for ($i = 0; $i -lt $items.Count; $i++) {
        [Console]::SetCursorPosition(0, $top + $i)
        $line = "  $($items[$i].Text)"; if ($i -eq $sel) { $line = "> $($items[$i].Text)" }
        $line = $line.PadRight($width).Substring(0, $width)
        if ($i -eq $sel) { Write-Host $line -ForegroundColor Cyan -NoNewline } else { Write-Host $line -NoNewline }
      }
      $key = [Console]::ReadKey($true)
      switch ($key.Key) {
        'UpArrow'   { $sel = ($sel + $items.Count - 1) % $items.Count }
        'DownArrow' { $sel = ($sel + 1) % $items.Count }
        'Enter'     { [Console]::SetCursorPosition(0, $top + $items.Count); Write-Host ''; return $sel }
        default     { if ($key.KeyChar -match '^[1-9]$' -and [int]"$($key.KeyChar)" -le $items.Count) { $sel = [int]"$($key.KeyChar)" - 1 } }
      }
    }
  } finally { [Console]::CursorVisible = $true }
}

$choice = $entries[(Show-Menu $entries)]
$model = $choice.Tag
if (-not $Mode) { $Mode = 'chat'; if ($choice.Use -eq 'coding') { $Mode = 'claude' } }

if ($Mode -eq 'claude') {
  $nativeClaude = Join-Path $HOME '.local\bin\claude.exe'
  if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not (Test-Path $nativeClaude)) {
    Die "Claude Code isn't installed. Run 'install.ps1 --use coding' to install it, or use --chat."
  }
  Say "Starting Claude Code with $model in $((Get-Location).Path)"
  & $ollama launch claude --model $model
  exit $LASTEXITCODE
}
Say "Chatting with $model. Type /bye to stop."
& $ollama run $model
exit $LASTEXITCODE
