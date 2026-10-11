#!/usr/bin/env bash
# Installs or updates Ollama (and Claude Code for coding), then three local models sized for this machine.
# macOS + Linux. Usage: ./install.sh [--use coding|writing|...] [--tier light,medium,heavy|all] [--budget GB] [--dry-run] [--yes] [--no-context] [--no-claude]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS_FILE="$HERE/models.txt"
MIN_OLLAMA="0.14.0"
REGISTRY="https://registry.ollama.ai/v2"
SERVER="http://localhost:11434"
GB=1000000000

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s[ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%sWarning: %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%sError: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
ask()  { # ask "question" [Y] -> success if the user says yes. With Y, pressing Enter means yes. --yes skips it.
  [ "$YES" = 1 ] && return 0
  local a hint="[y/N]"; [ "${2:-}" = Y ] && hint="[Y/n]"
  printf '%s %s ' "$1" "$hint"; read -r a </dev/tty || return 1
  [ -z "$a" ] && [ "${2:-}" = Y ] && return 0
  case "$a" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}
human() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }
gib()   { awk -v b="$1" 'BEGIN { printf "%d", b / 1073741824 + 0.5 }'; }   # bytes -> whole GB
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }  # $1 >= $2

TIER=all; USE=""; BUDGET_OVERRIDE=""; DRY=0; YES=0; NO_CTX=0; NO_CLAUDE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="${2:-}"; shift ;;
    --use) USE=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z'); shift ;;
    --budget) BUDGET_OVERRIDE="${2:-}"; shift ;;
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --no-context) NO_CTX=1 ;;
    --no-claude) NO_CLAUDE=1 ;;
    -h|--help) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done
WANT=""
for t in $(printf '%s' "$TIER" | tr ',' ' ' | tr 'A-Z' 'a-z'); do
  case "$t" in
    all) WANT="light medium heavy" ;;
    light|low) WANT="$WANT light" ;;
    medium|mid) WANT="$WANT medium" ;;
    heavy|high) WANT="$WANT heavy" ;;
    *) WANT=""; break ;;
  esac
done
[ -n "$WANT" ] || die "--tier takes light, medium, heavy or all. Pick several with commas, e.g. --tier light,medium"
if [ -n "$BUDGET_OVERRIDE" ] && ! [[ "$BUDGET_OVERRIDE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  die "--budget needs a number of GB, e.g. --budget 24"
fi
[ -r "$MODELS_FILE" ] || die "Can't read $MODELS_FILE (it must sit next to this script)."
[ "$DRY" = 1 ] && say "${B}Dry run:${N} nothing will be installed or changed."

# ---------------------------------------------------------------------------
# Step 1: detect hardware and work out the memory budget (GB a model can use)
# ---------------------------------------------------------------------------
step "Checking your hardware"
OS="$(uname -s)"; APPLE=0; HAS_GPU=0
if [ "$OS" = Darwin ]; then
  RAM_GB=$(gib "$(sysctl -n hw.memsize)")
  # hw.optional.arm64 is 1 on Apple Silicon even if this shell runs under Rosetta (where uname -m says x86_64).
  if [ "$(uname -m)" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
    APPLE=1; HAS_GPU=1; HW="Apple Silicon Mac with ${RAM_GB}GB unified memory"
    BUDGET=$(( RAM_GB * 3 / 4 ))   # macOS only lets the GPU use about 75% of unified memory
  else
    HW="Intel Mac with ${RAM_GB}GB RAM (no usable GPU)"; BUDGET=$(( RAM_GB / 2 ))
  fi
elif [ "$OS" = Linux ]; then
  RAM_GB=$(awk '/^MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
  # NVIDIA: nvidia-smi reports each card's VRAM in MiB; use the largest card.
  NV=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1)
  # AMD: rocm-smi prints "GPU[0] : VRAM Total Memory (B): <bytes>" (plus "Total Used" lines we skip).
  AMD=$(rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Total Memory/ && !/Used/ { gsub(/ /, "", $NF); print $NF }' | sort -n | tail -1)
  if [[ "$NV" =~ ^[0-9]+$ ]]; then
    HAS_GPU=1; BUDGET=$(( (NV + 512) / 1024 )); HW="NVIDIA GPU with ${BUDGET}GB VRAM (${RAM_GB}GB system RAM)"
  elif [[ "$AMD" =~ ^[0-9]+$ ]]; then
    HAS_GPU=1; BUDGET=$(gib "$AMD"); HW="AMD GPU with ${BUDGET}GB VRAM (${RAM_GB}GB system RAM)"
  else
    HW="no supported GPU found, ${RAM_GB}GB RAM"; BUDGET=$(( RAM_GB / 2 ))
  fi
else
  die "Unsupported system: $OS. On Windows, run install.ps1 instead."
fi
say "Detected: $HW"
[ "$HAS_GPU" = 0 ] && warn "No usable GPU, so models will run on the CPU. Expect slow answers."
if [ -n "$BUDGET_OVERRIDE" ]; then
  say "Memory budget: ${BUDGET}GB detected, using your override of ${BUDGET_OVERRIDE%.*}GB"; BUDGET=${BUDGET_OVERRIDE%.*}
else
  say "Memory budget: ${BUDGET}GB (override with --budget <GB>)"
fi

# ---------------------------------------------------------------------------
# Step 2: pick the tier row from models.txt and check each tag exists
# ---------------------------------------------------------------------------
step "Choosing models"
# models.txt has one "[use] description" section per use; rows before any section count as coding.
list_uses() { sed 's/#.*//' "$MODELS_FILE" | sed -n 's/^[[:space:]]*\[\([a-z0-9_-]*\)\][[:space:]]*\(.*\)$/\1|\2/p'; }
section_rows() {
  sed 's/#.*//' "$MODELS_FILE" | awk -v want="$1" '
    /^[[:space:]]*\[/ { cur = $0; sub(/^[[:space:]]*\[/, "", cur); sub(/\].*/, "", cur); next }
    NF >= 4 && (cur == want || (cur == "" && want == "coding")) { print $1, $2, $3, $4 }'
}
USES=$(list_uses); [ -n "$USES" ] || USES="coding|Writing and fixing code"
USE_NAMES=$(printf '%s\n' "$USES" | cut -d'|' -f1)
if [ -z "$USE" ]; then
  USE=$(printf '%s\n' "$USE_NAMES" | head -1)
  if [ "$YES" = 0 ] && [ "$(printf '%s\n' "$USES" | wc -l)" -gt 1 ]; then
    say "What will you mainly use these models for? The best models differ a lot by task."
    printf '%s\n' "$USES" | awk -F'|' '{ printf "  %d) %-9s %s\n", NR, $1, $2 }'
    while :; do
      printf 'Choose a number [1]: '; read -r answer </dev/tty || answer=""
      [ -z "$answer" ] && break
      if [[ "$answer" =~ ^[0-9]+$ ]]; then PICK=$(printf '%s\n' "$USE_NAMES" | sed -n "${answer}p"); else PICK=""; fi
      [ -n "$PICK" ] && { USE=$PICK; break; }
      warn "Please type one of the numbers above."
    done
  fi
fi
printf '%s\n' "$USE_NAMES" | grep -qxF "$USE" || die "Unknown --use '$USE'. Choose from: $(printf '%s ' $USE_NAMES)"
FITS=$(section_rows "$USE" | sort -n | awk -v b="$BUDGET" '$1 <= b')
[ -n "$FITS" ] || die "No row in the [$USE] section of models.txt fits a ${BUDGET}GB budget."
ROW=$(printf '%s\n' "$FITS" | tail -1)
if [ "$HAS_GPU" = 0 ] && [ -z "$BUDGET_OVERRIDE" ] && [ "${ROW%% *}" -ge 16 ] && [ "$(printf '%s\n' "$FITS" | wc -l)" -gt 1 ]; then
  LOWER=$(printf '%s\n' "$FITS" | tail -2 | head -1)
  warn "Without a GPU the ${ROW%% *}GB row would be painfully slow, so using the ${LOWER%% *}GB row instead."
  ROW=$LOWER
fi
set -- $ROW
say "Using the ${1}GB+ row of the [$USE] models (choose another use with --use)"
TIERS=(light medium heavy); SPECS=("$2" "$3" "$4")

manifest_size() { # tag -> prints total download bytes. Returns 0 found, 1 not found, 2 couldn't check
  local name="${1%%:*}" tag=latest out code
  case "$1" in *:*) tag="${1#*:}" ;; esac
  case "$name" in */*) ;; *) name="library/$name" ;; esac
  out=$(curl -sS -m 15 -w '\n%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "$REGISTRY/$name/manifests/$tag" 2>/dev/null) || return 2
  code="${out##*$'\n'}"
  case "$code" in 200) ;; 404) return 1 ;; *) return 2 ;; esac
  printf '%s' "$out" | grep -oE '"size": *[0-9]+' | awk -F: '{ s += $2 } END { print s + 0 }'
}
resolve() { # "a|b" -> sets TAG, SIZE, NOTE (TAG empty if nothing exists)
  local first="${1%%|*}" alt rc mlx_size
  TAG=""; SIZE=0; NOTE=""
  for alt in $(printf '%s' "$1" | tr '|' ' '); do
    SIZE=$(manifest_size "$alt"); rc=$?
    if [ $rc = 2 ]; then TAG=$first; SIZE=0; NOTE="couldn't reach ollama.com to check this tag; will try anyway"; return; fi
    [ $rc = 1 ] && continue
    TAG=$alt
    [ "$alt" != "$first" ] && NOTE="$first is not published, falling back to $alt"
    # On Apple Silicon prefer the MLX build of plain tags (qwen3.8:27b -> qwen3.8:27b-mlx), but only when it is
    # at most 10% bigger: some MLX builds are far larger (qwen3.5:9b is 6.6 GB, its MLX build 8.9 GB) and wouldn't fit.
    if [ "$APPLE" = 1 ] && [[ "$alt" == *:* && "${alt#*:}" != *-* ]] &&
       mlx_size=$(manifest_size "$alt-mlx") && [ "$mlx_size" -le $(( SIZE * 11 / 10 )) ]; then
      TAG="$alt-mlx"; SIZE=$mlx_size; NOTE="${NOTE:+$NOTE; }MLX build, faster on Apple Silicon"
    fi
    return
  done
  NOTE="'${1//|/ or }' was not found on ollama.com (renamed? edit models.txt)"
}
P_TIER=(); P_TAG=(); P_SIZE=(); P_NOTE=(); MISSING=""
for i in 0 1 2; do
  [[ " $WANT " == *" ${TIERS[$i]} "* ]] || continue
  [ "${SPECS[$i]}" = "-" ] && continue   # "-" in models.txt means no model for this tier
  resolve "${SPECS[$i]}"
  if [ -z "$TAG" ]; then warn "${TIERS[$i]}: $NOTE"; MISSING="$MISSING ${TIERS[$i]}"; continue; fi
  P_TIER+=("${TIERS[$i]}"); P_TAG+=("$TAG"); P_SIZE+=("$SIZE"); P_NOTE+=("$NOTE")
done
[ ${#P_TAG[@]} -gt 0 ] || die "None of the chosen models could be found. Check the tags in models.txt."

# ---------------------------------------------------------------------------
# Step 3: make sure Ollama is installed, new enough and running
# ---------------------------------------------------------------------------
step "Checking Ollama"
APP_BIN=/Applications/Ollama.app/Contents/Resources/ollama
find_ollama() {
  OLLAMA=$(command -v ollama 2>/dev/null || true)
  # A freshly installed Mac app hasn't put its CLI on PATH yet, so use the copy inside the app.
  if [ -z "$OLLAMA" ] && [ -x "$APP_BIN" ]; then OLLAMA=$APP_BIN; fi
}
ollama_version() { "$OLLAMA" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; }
stop_mac_app() { # quit the Ollama app and its server; succeeds once nothing is left running
  pgrep -f 'Ollama.app/Contents' >/dev/null || return 0
  osascript -e 'quit app "Ollama"' >/dev/null 2>&1
  for _ in $(seq 10); do pgrep -f 'Ollama.app/Contents' >/dev/null || return 0; sleep 1; done
  pkill -f 'Ollama.app/Contents'   # the app can ignore the quit request (seen with 0.23.2)
  for _ in $(seq 10); do pgrep -f 'Ollama.app/Contents' >/dev/null || return 0; sleep 1; done
  return 1
}
install_mac_app() { # download the official app, check Apple's signature, swap it into /Applications
  local tmp; tmp=$(mktemp -d)
  say "Downloading the Ollama app..."
  curl -fL --progress-bar -o "$tmp/Ollama.zip" https://ollama.com/download/Ollama-darwin.zip || { warn "Download failed."; return 1; }
  if ! ditto -x -k "$tmp/Ollama.zip" "$tmp/new" || ! codesign --verify --deep --strict "$tmp/new/Ollama.app" 2>/dev/null; then
    warn "The downloaded app failed Apple's signature check, so it was not installed."; return 1
  fi
  if [ -d /Applications/Ollama.app ]; then
    stop_mac_app || { warn "Couldn't quit the running Ollama. Quit it from the menu bar, then re-run."; return 1; }
    mv /Applications/Ollama.app "$tmp/Ollama-old.app" || { warn "Couldn't move the old app out of /Applications."; return 1; }
  fi
  if ! mv "$tmp/new/Ollama.app" /Applications/; then
    [ -d "$tmp/Ollama-old.app" ] && mv "$tmp/Ollama-old.app" /Applications/
    warn "Couldn't copy the new app into /Applications."; return 1
  fi
  open -a Ollama
  ok "Ollama app installed${LATEST:+ ($LATEST)}. Any previous version was kept in $tmp"
}
install_ollama() { # $1 = Install|Update
  local method label
  if [ "$OS" = Linux ]; then method=script; label="the official installer from ollama.com (uses sudo)"
  elif brew list --formula ollama >/dev/null 2>&1; then method=brew; label="Homebrew (brew upgrade ollama)"
  elif [ "$1" = Install ] && command -v brew >/dev/null 2>&1; then method=brew; label="Homebrew (brew install ollama)"
  else method=app; label="the official Mac app from ollama.com"; fi
  ask "$1 Ollama${LATEST:+ to $LATEST} with $label?" Y || return 1
  case $method in
    script) curl -fsSL https://ollama.com/install.sh | sh ;;
    brew) if [ "$1" = Install ]; then brew install ollama; else brew upgrade ollama; fi ;;
    app) install_mac_app ;;
  esac
}
LATEST=$(curl -fsS -m 10 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null |
         grep -m1 '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$LATEST" ] || warn "Couldn't look up the latest Ollama version (offline?), so it won't be updated."
find_ollama
if [ -z "$OLLAMA" ]; then
  say "Ollama is not installed."
  if [ "$DRY" = 1 ]; then say "(dry run) Would install Ollama${LATEST:+ $LATEST} now."
  else
    install_ollama Install || die "Ollama is required. Install it from https://ollama.com/download, then re-run this script."
    find_ollama; [ -n "$OLLAMA" ] || die "Ollama was installed but can't be found yet. Open a new terminal and re-run."
  fi
fi
if [ -n "$OLLAMA" ]; then
  V=$(ollama_version)
  if [ -n "$LATEST" ] && [ -n "$V" ] && ! ver_ge "$V" "$LATEST"; then
    say "Ollama $V is installed; the latest is $LATEST."
    if [ "$DRY" = 1 ]; then say "(dry run) Would update Ollama to $LATEST."
    elif install_ollama Update; then find_ollama; V=$(ollama_version)
    else warn "Keeping Ollama $V. Newer models may refuse to download."; fi
  fi
  if [ -n "$V" ] && ver_ge "$V" "$MIN_OLLAMA"; then ok "Ollama $V"
  elif [ "$DRY" = 1 ]; then warn "Ollama ${V:-(unknown version)} is older than $MIN_OLLAMA, which Claude Code needs."
  else die "Ollama ${V:-(unknown version)} is older than $MIN_OLLAMA, which Claude Code needs. Update it, then re-run."; fi
fi

server_up() { curl -s -m 2 -o /dev/null "$SERVER"; }
if [ "$DRY" = 0 ] && ! server_up; then
  say "Starting the Ollama server..."
  if [ "$OS" = Darwin ] && [ -d /Applications/Ollama.app ]; then open -a Ollama
  elif [ "$OS" = Linux ] && systemctl cat ollama >/dev/null 2>&1; then
    ask "Start the ollama system service (uses sudo)?" && sudo systemctl start ollama
  else mkdir -p "$HOME/.ollama"; nohup "$OLLAMA" serve >"$HOME/.ollama/serve.log" 2>&1 &
  fi
  for _ in $(seq 30); do server_up && break; sleep 1; done
  server_up || die "The Ollama server didn't start within 30 seconds. Try running 'ollama serve' yourself."
fi
server_up && ok "Ollama server is running" && INSTALLED=$("$OLLAMA" list 2>/dev/null | awk 'NR > 1 { print $1 }') || INSTALLED=""
# After an update, a server started earlier may still be the old version, and new models would be refused.
server_version() { curl -s -m 2 "$SERVER/api/version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
SERVER_V=$(server_version)
if [ -n "$SERVER_V" ] && [ -n "${V:-}" ] && [ "$SERVER_V" != "$V" ]; then
  if [ "$DRY" = 1 ]; then warn "The running Ollama server is version $SERVER_V, not $V. A real run would restart it."
  else
    if [ "$OS" = Darwin ] && [ -d /Applications/Ollama.app ] && ask "The running Ollama server is still $SERVER_V. Restart Ollama so it uses $V?" Y; then
      stop_mac_app && open -a Ollama
      for _ in $(seq 30); do [ "$(server_version)" = "$V" ] && break; sleep 1; done
    fi
    SERVER_V=$(server_version)
    [ "$SERVER_V" = "$V" ] || die "The running Ollama server is version ${SERVER_V:-unknown}, not $V. Restart Ollama, then re-run this script."
    ok "Ollama server restarted on $V"
  fi
fi
is_installed() { printf '%s\n' "$INSTALLED" | grep -qxF "$1" || printf '%s\n' "$INSTALLED" | grep -qxF "$1:latest"; }

# ---------------------------------------------------------------------------
# Step 3b: install or update Claude Code, which `ollama launch claude` starts
# ---------------------------------------------------------------------------
CLAUDE=""
if [ "$NO_CLAUDE" = 0 ] && [ "$USE" = coding ]; then
  step "Checking Claude Code"
  CLAUDE=$(command -v claude 2>/dev/null || true)
  # The official installer puts claude in ~/.local/bin, which may not be on PATH until a new terminal opens.
  if [ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ]; then CLAUDE="$HOME/.local/bin/claude"; fi
  if [ -z "$CLAUDE" ]; then
    say "Claude Code is not installed."
    if [ "$DRY" = 1 ]; then say "(dry run) Would install Claude Code with the official installer."
    elif ask "Install Claude Code with the official installer from claude.ai?" Y; then
      if curl -fsSL https://claude.ai/install.sh | bash; then CLAUDE="$HOME/.local/bin/claude"
      else warn "Claude Code didn't install. See https://code.claude.com/docs/en/setup"; fi
    else warn "Skipping Claude Code. You'll need it for 'ollama launch claude'."; fi
  elif [ "$DRY" = 1 ]; then say "Claude Code is installed. (dry run) Would update it to the latest version."
  elif ask "Claude Code $("$CLAUDE" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) is installed. Update it to the latest version?" Y; then
    if command -v brew >/dev/null 2>&1 && brew list --cask claude-code@latest >/dev/null 2>&1; then brew upgrade --cask claude-code@latest
    elif command -v brew >/dev/null 2>&1 && brew list --cask claude-code >/dev/null 2>&1; then brew upgrade --cask claude-code
    else "$CLAUDE" update; fi || warn "Claude Code couldn't be updated; carrying on with the installed version."
  else say "Keeping the installed Claude Code."
  fi
  [ -n "$CLAUDE" ] && [ -x "$CLAUDE" ] && ok "$("$CLAUDE" --version 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------------------
# Step 4: summary, disk check, confirm, download
# ---------------------------------------------------------------------------
step "Plan"
MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"
[ "$OS" = Linux ] && [ -z "${OLLAMA_MODELS:-}" ] && [ -d /usr/share/ollama/.ollama ] && MODELS_DIR=/usr/share/ollama/.ollama/models
d="$MODELS_DIR"; while [ ! -d "$d" ]; do d=$(dirname "$d"); done
FREE=$(( $(df -Pk "$d" | awk 'NR == 2 { print $4 }') * 1024 ))
say "Hardware: $HW"
say "Budget:   ${BUDGET}GB"
for i in "${!P_TAG[@]}"; do
  t=${P_TAG[$i]}; s=${P_SIZE[$i]}
  if is_installed "$t"; then status="already installed"
  elif [ "$s" -gt 0 ]; then status="$(human "$s") download"
  else status="download size unknown"; fi
  printf '  %-7s %-28s %s\n' "${P_TIER[$i]}" "$t" "$status"
  [ -n "${P_NOTE[$i]}" ] && printf '          (%s)\n' "${P_NOTE[$i]}"
done

TOTAL=0; TODO=()
for i in "${!P_TAG[@]}"; do   # at most 3 models, so the duplicate check below is trivially cheap
  t=${P_TAG[$i]}
  is_installed "$t" || [[ " ${TODO[*]-} " == *" $t "* ]] && continue
  TODO+=("$t"); TOTAL=$(( TOTAL + P_SIZE[i] ))
done
say "To download: ${#TODO[@]} model(s), $(human $TOTAL)   Free disk space: $(human $FREE) (in $d)"
if [ ${#TODO[@]} -gt 0 ] && [ "$FREE" -lt $(( TOTAL + 10 * GB )) ]; then
  [ "$DRY" = 1 ] && { warn "Not enough disk space: need $(human $(( TOTAL + 10 * GB ))) free (downloads + 10 GB headroom). A real run would stop here."; exit 1; }
  die "Not enough disk space: need $(human $(( TOTAL + 10 * GB ))) free (downloads + 10 GB headroom). Free up space or pick fewer with --tier."
fi
CTX=32768; [ "$BUDGET" -ge 28 ] && CTX=65536
if [ "$DRY" = 1 ]; then
  [ "$NO_CTX" = 0 ] && say "Would set OLLAMA_CONTEXT_LENGTH=$CTX."
  say "Dry run finished. Run without --dry-run to install."; exit 0
fi
FAILED=""
if [ ${#TODO[@]} -gt 0 ]; then
  ask "Download ${#TODO[@]} model(s), $(human $TOTAL) in total?" Y || die "Cancelled. Nothing was downloaded."
  for t in "${TODO[@]}"; do
    step "Downloading $t"
    # Don't pipe this: ollama sizes its progress bar from the terminal, and through a pipe it redraws as new lines.
    "$OLLAMA" pull "$t" || { FAILED="$FAILED $t"; warn "Download of $t failed; carrying on."; }
  done
else ok "All of these models are already installed."; fi

# ---------------------------------------------------------------------------
# Step 5: raise Ollama's context window so coding agents can see enough code
# ---------------------------------------------------------------------------
if [ "$NO_CTX" = 0 ]; then
  step "Context window"
  if [ "$OS" = Darwin ]; then
    if [ "$(launchctl getenv OLLAMA_CONTEXT_LENGTH)" = "$CTX" ]; then ok "OLLAMA_CONTEXT_LENGTH is already $CTX"
    elif ask "Set Ollama's context window to $CTX tokens (default 4096 is too small for coding agents)?"; then
      launchctl setenv OLLAMA_CONTEXT_LENGTH "$CTX" && ok "Set for this login session. Quit Ollama from the menu bar and reopen it to apply."
      if ask "launchctl settings reset on reboot. Also add it to ~/.zshrc?"; then
        if grep -q '^export OLLAMA_CONTEXT_LENGTH=' "$HOME/.zshrc" 2>/dev/null; then
          sed -i '' "s/^export OLLAMA_CONTEXT_LENGTH=.*/export OLLAMA_CONTEXT_LENGTH=$CTX/" "$HOME/.zshrc"
        else printf '\nexport OLLAMA_CONTEXT_LENGTH=%s\n' "$CTX" >>"$HOME/.zshrc"; fi
        ok "Added to ~/.zshrc (applies when you start 'ollama serve' from a terminal)."
      fi
    fi
  elif systemctl cat ollama >/dev/null 2>&1; then
    if systemctl show ollama --property=Environment | grep -q "OLLAMA_CONTEXT_LENGTH=$CTX"; then ok "OLLAMA_CONTEXT_LENGTH is already $CTX"
    elif ask "Set the ollama service's context window to $CTX tokens (uses sudo, restarts Ollama)?"; then
      printf '[Service]\nEnvironment="OLLAMA_CONTEXT_LENGTH=%s"\n' "$CTX" |
        sudo sh -c 'mkdir -p /etc/systemd/system/ollama.service.d && cat > /etc/systemd/system/ollama.service.d/context.conf' &&
        sudo systemctl daemon-reload && sudo systemctl restart ollama && ok "Context window set to $CTX" ||
        warn "Couldn't update the ollama service. Set OLLAMA_CONTEXT_LENGTH=$CTX yourself."
    fi
  else
    say "No ollama system service found. Add 'export OLLAMA_CONTEXT_LENGTH=$CTX' to your shell profile before running 'ollama serve'."
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: what's installed and how to use it
# ---------------------------------------------------------------------------
step "All done"
FIRST=""
for i in "${!P_TAG[@]}"; do
  t=${P_TAG[$i]}
  [[ " $FAILED " == *" $t "* ]] && continue
  case "$USE ${P_TIER[$i]}" in
    "coding light")  use="quick questions, explanations and autocomplete (fastest)" ;;
    "coding medium") use="everyday coding: writing functions, fixing bugs, reviews" ;;
    "coding heavy")  use="hard problems, big refactors and agent work (slowest, smartest)" ;;
    *light)  use="fastest, for quick tasks" ;;
    *medium) use="balanced, for everyday use" ;;
    *heavy)  use="best quality, slowest" ;;
  esac
  is_installed "$t" && use="$use [already had it]"
  printf '  %s%-7s%s %-28s %s\n' "$B" "${P_TIER[$i]}" "$N" "$t" "$use"
  [ -z "$FIRST" ] && FIRST=$t
done
[ -z "$FIRST" ] && say "  No models were installed this time."
say ""
[ -n "$FIRST" ] && say "Try a model:          ollama run $FIRST"
[ "$USE" = coding ] && say "Use with Claude Code: ollama launch claude   (then pick a model)"
[ -n "$CLAUDE" ] && ! command -v claude >/dev/null 2>&1 && say "                      (open a new terminal first so 'claude' is on your PATH)"
say "Remove a model:       ollama rm <model>"
[ -n "$MISSING" ] && warn "Skipped because the tag wasn't found:$MISSING"
if [ -n "$FAILED" ] && [ -n "$LATEST" ] && [ -n "${V:-}" ] && ! ver_ge "$V" "$LATEST"; then
  warn "Your Ollama ($V) is older than the latest ($LATEST), and new models often need it. Re-run this script and accept the Ollama update."
fi
[ -n "$FAILED" ] && { warn "These downloads failed:$FAILED. Re-run this script to retry."; exit 1; }
exit 0
