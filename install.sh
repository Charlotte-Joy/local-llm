#!/usr/bin/env bash
# Installs Ollama (if needed) and three local coding models sized for this machine.
# macOS + Linux. Usage: ./install.sh [--tier light|medium|heavy|all] [--budget GB] [--dry-run] [--yes] [--no-context]
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
ask()  { # ask "question" -> success if the user says yes (always yes with --yes)
  [ "$YES" = 1 ] && return 0
  local a; printf '%s [y/N] ' "$1"; read -r a </dev/tty || return 1
  case "$a" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}
human() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }
gib()   { awk -v b="$1" 'BEGIN { printf "%d", b / 1073741824 + 0.5 }'; }   # bytes -> whole GB
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }  # $1 >= $2

TIER=all; BUDGET_OVERRIDE=""; DRY=0; YES=0; NO_CTX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="${2:-}"; shift ;;
    --budget) BUDGET_OVERRIDE="${2:-}"; shift ;;
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --no-context) NO_CTX=1 ;;
    -h|--help) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done
case "$TIER" in light|medium|heavy|all) ;; *) die "--tier must be light, medium, heavy or all" ;; esac
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
FITS=$(sed 's/#.*//' "$MODELS_FILE" | awk 'NF >= 4 { print $1, $2, $3, $4 }' | sort -n | awk -v b="$BUDGET" '$1 <= b')
[ -n "$FITS" ] || die "No row in models.txt fits a ${BUDGET}GB budget."
ROW=$(printf '%s\n' "$FITS" | tail -1)
if [ "$HAS_GPU" = 0 ] && [ -z "$BUDGET_OVERRIDE" ] && [ "${ROW%% *}" -ge 16 ] && [ "$(printf '%s\n' "$FITS" | wc -l)" -gt 1 ]; then
  LOWER=$(printf '%s\n' "$FITS" | tail -2 | head -1)
  warn "Without a GPU the ${ROW%% *}GB row would be painfully slow, so using the ${LOWER%% *}GB row instead."
  ROW=$LOWER
fi
set -- $ROW
say "Using the ${1}GB+ row of models.txt"
TIERS=(light medium heavy); SPECS=("$2" "$3" "$4")

manifest_size() { # tag -> prints total download bytes. Returns 0 found, 1 not found, 2 couldn't check
  local name="${1%%:*}" tag=latest out code
  case "$1" in *:*) tag="${1#*:}" ;; esac
  case "$name" in */*) ;; *) name="library/$name" ;; esac
  out=$(curl -sS -m 15 -w '\n%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "$REGISTRY/$name/manifests/$tag" 2>/dev/null) || return 2
  code="${out##*$'\n'}"
  case "$code" in 200) ;; 404) return 1 ;; *) return 2 ;; esac
  printf '%s' "$out" | grep -o '"size":[0-9]*' | awk -F: '{ s += $2 } END { print s + 0 }'
}
resolve() { # "a|b" -> sets TAG, SIZE, NOTE (TAG empty if nothing exists)
  local first="${1%%|*}" alt c cands rc
  TAG=""; SIZE=0; NOTE=""
  for alt in $(printf '%s' "$1" | tr '|' ' '); do
    cands="$alt"
    # On Apple Silicon prefer the MLX build of plain tags (qwen3.8:27b -> qwen3.8:27b-mlx).
    [ "$APPLE" = 1 ] && [[ "$alt" == *:* && "${alt#*:}" != *-* ]] && cands="$alt-mlx $alt"
    for c in $cands; do
      SIZE=$(manifest_size "$c"); rc=$?
      if [ $rc = 2 ]; then TAG=$first; SIZE=0; NOTE="couldn't reach ollama.com to check this tag; will try anyway"; return; fi
      if [ $rc = 0 ]; then
        TAG=$c
        [ "$alt" != "$first" ] && NOTE="$first is not published, falling back to $alt"
        [ "$c" != "$alt" ] && NOTE="${NOTE:+$NOTE; }MLX build, faster on Apple Silicon"
        return
      fi
    done
  done
  NOTE="'${1//|/ or }' was not found on ollama.com (renamed? edit models.txt)"
}
P_TIER=(); P_TAG=(); P_SIZE=(); P_NOTE=(); MISSING=""
for i in 0 1 2; do
  [ "$TIER" = all ] || [ "$TIER" = "${TIERS[$i]}" ] || continue
  resolve "${SPECS[$i]}"
  if [ -z "$TAG" ]; then warn "${TIERS[$i]}: $NOTE"; MISSING="$MISSING ${TIERS[$i]}"; continue; fi
  P_TIER+=("${TIERS[$i]}"); P_TAG+=("$TAG"); P_SIZE+=("$SIZE"); P_NOTE+=("$NOTE")
done
[ ${#P_TAG[@]} -gt 0 ] || die "None of the chosen models could be found. Check the tags in models.txt."

# ---------------------------------------------------------------------------
# Step 3: make sure Ollama is installed, new enough and running
# ---------------------------------------------------------------------------
step "Checking Ollama"
ollama_version() { ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; }
install_ollama() { # $1 = install|upgrade
  if [ "$OS" = Darwin ]; then
    if command -v brew >/dev/null 2>&1 && { [ "$1" = install ] || brew list --formula ollama >/dev/null 2>&1; }; then
      ask "$1 Ollama with Homebrew (brew $1 ollama)?" || return 1
      brew "$1" ollama
    else
      say "Please download the Ollama app from https://ollama.com/download, open it once, then re-run this script."
      return 1
    fi
  else
    say "The official Ollama installer (https://ollama.com/install.sh) needs sudo to install system-wide."
    ask "Run it now?" || return 1
    curl -fsSL https://ollama.com/install.sh | sh
  fi
}
if ! command -v ollama >/dev/null 2>&1; then
  say "Ollama is not installed."
  if [ "$DRY" = 1 ]; then say "(dry run) Would install Ollama now."
  else install_ollama install || die "Ollama is required. Install it, then re-run this script."
       command -v ollama >/dev/null 2>&1 || die "Ollama still isn't on your PATH. Open a new terminal and re-run."
  fi
fi
if command -v ollama >/dev/null 2>&1; then
  V=$(ollama_version)
  if [ -n "$V" ] && ver_ge "$V" "$MIN_OLLAMA"; then ok "Ollama $V"
  else
    warn "Ollama ${V:-(unknown version)} is older than $MIN_OLLAMA, which Claude Code needs."
    if [ "$DRY" = 1 ]; then say "(dry run) Would offer to upgrade."
    else install_ollama upgrade || die "Please upgrade Ollama to $MIN_OLLAMA or newer, then re-run."; fi
  fi
fi

server_up() { curl -s -m 2 -o /dev/null "$SERVER"; }
if [ "$DRY" = 0 ] && ! server_up; then
  say "Starting the Ollama server..."
  if [ "$OS" = Darwin ] && [ -d /Applications/Ollama.app ]; then open -a Ollama
  elif [ "$OS" = Linux ] && systemctl cat ollama >/dev/null 2>&1; then
    ask "Start the ollama system service (uses sudo)?" && sudo systemctl start ollama
  else mkdir -p "$HOME/.ollama"; nohup ollama serve >"$HOME/.ollama/serve.log" 2>&1 &
  fi
  for _ in $(seq 30); do server_up && break; sleep 1; done
  server_up || die "The Ollama server didn't start within 30 seconds. Try running 'ollama serve' yourself."
fi
server_up && ok "Ollama server is running" && INSTALLED=$(ollama list 2>/dev/null | awk 'NR > 1 { print $1 }') || INSTALLED=""
is_installed() { printf '%s\n' "$INSTALLED" | grep -qxF "$1" || printf '%s\n' "$INSTALLED" | grep -qxF "$1:latest"; }

# ---------------------------------------------------------------------------
# Step 4: summary, disk check, confirm, download
# ---------------------------------------------------------------------------
step "Plan"
MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"
[ "$OS" = Linux ] && [ -z "${OLLAMA_MODELS:-}" ] && [ -d /usr/share/ollama/.ollama ] && MODELS_DIR=/usr/share/ollama/.ollama/models
d="$MODELS_DIR"; while [ ! -d "$d" ]; do d=$(dirname "$d"); done
FREE=$(( $(df -Pk "$d" | awk 'NR == 2 { print $4 }') * 1024 ))
TOTAL=0; TODO=()
say "Hardware: $HW"
say "Budget:   ${BUDGET}GB"
for i in "${!P_TAG[@]}"; do
  t=${P_TAG[$i]}; s=${P_SIZE[$i]}; size=$( [ "$s" -gt 0 ] && echo "$(human "$s") to download" || echo "download size unknown")
  if is_installed "$t"; then status="already installed"
  elif [[ " ${TODO[*]-} " == *" $t "* ]]; then status="same model as above"
  else status="$size"; TODO+=("$t"); TOTAL=$(( TOTAL + s )); fi
  printf '  %-7s %-28s %s\n' "${P_TIER[$i]}" "$t" "$status"
  [ -n "${P_NOTE[$i]}" ] && printf '          (%s)\n' "${P_NOTE[$i]}"
done
say "Total download: $(human $TOTAL)   Free disk space: $(human $FREE) (in $d)"
if [ ${#TODO[@]} -gt 0 ] && [ "$FREE" -lt $(( TOTAL + 10 * GB )) ]; then
  [ "$DRY" = 1 ] && { warn "Not enough disk space: need $(human $(( TOTAL + 10 * GB ))) free (downloads + 10 GB headroom). A real run would stop here."; exit 1; }
  die "Not enough disk space: need $(human $(( TOTAL + 10 * GB ))) free (downloads + 10 GB headroom). Free up space or use --tier."
fi
CTX=32768; [ "$BUDGET" -ge 28 ] && CTX=65536
if [ "$DRY" = 1 ]; then
  [ "$NO_CTX" = 0 ] && say "Would set OLLAMA_CONTEXT_LENGTH=$CTX."
  say "Dry run finished. Run without --dry-run to install."; exit 0
fi
FAILED=""
if [ ${#TODO[@]} -gt 0 ]; then
  ask "Download ${#TODO[@]} model(s) now?" || die "Cancelled. Nothing was downloaded."
  for t in "${TODO[@]}"; do
    step "Downloading $t"
    ollama pull "$t" || { FAILED="$FAILED $t"; warn "Download of $t failed; carrying on."; }
  done
else ok "All chosen models are already installed."; fi

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
for i in "${!P_TAG[@]}"; do
  t=${P_TAG[$i]}
  [[ " $FAILED " == *" $t "* ]] && continue
  case ${P_TIER[$i]} in
    light)  use="quick questions, explanations and autocomplete (fastest)" ;;
    medium) use="everyday coding: writing functions, fixing bugs, reviews" ;;
    heavy)  use="hard problems, big refactors and agent work (slowest, smartest)" ;;
  esac
  printf '  %s%-7s%s %-28s %s\n' "$B" "${P_TIER[$i]}" "$N" "$t" "$use"
done
say ""
say "Try a model:          ollama run ${P_TAG[0]}"
command -v claude >/dev/null 2>&1 && say "Claude Code is installed on this machine, so you can use these models with it."
say "Use with Claude Code: ollama launch claude   (then pick a model)"
say "Remove a model:       ollama rm <model>"
[ -n "$MISSING" ] && warn "Skipped because the tag wasn't found:$MISSING"
[ -n "$FAILED" ] && { warn "These downloads failed:$FAILED. Re-run this script to retry."; exit 1; }
exit 0
