#!/usr/bin/env bash
# Launches one of your local models: pick light, medium or heavy with the arrow keys, then press Enter.
# Coding models open in Claude Code; writing and vision models open as a chat in this terminal.
# macOS + Linux. Usage: bash launch.sh [--claude|--chat]
set -u

STATE_FILE="$HOME/.local-llm/installed.txt"   # written by install.sh: "use tier model" per line
SERVER="http://localhost:11434"
APP_BIN=/Applications/Ollama.app/Contents/Resources/ollama

if [ -t 1 ]; then B=$'\033[1m'; C=$'\033[36m'; D=$'\033[2m'; R=$'\033[31m'; N=$'\033[0m'; else B=; C=; D=; R=; N=; fi
say() { printf '%s\n' "$*"; }
die() { printf '%sError: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

MODE=""
for arg in "$@"; do
  case "$arg" in
    --claude) MODE=claude ;;
    --chat) MODE=chat ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done
[ -t 0 ] || [ -r /dev/tty ] || die "Run this in a terminal so you can pick a model."

OLLAMA=$(command -v ollama 2>/dev/null || true)
if [ -z "$OLLAMA" ] && [ -x "$APP_BIN" ]; then OLLAMA=$APP_BIN; fi
[ -n "$OLLAMA" ] || die "Ollama isn't installed. Run 'bash install.sh' first."

server_up() { curl -s -m 2 -o /dev/null "$SERVER"; }
if ! server_up; then
  say "Starting Ollama..."
  if [ "$(uname -s)" = Darwin ] && [ -d /Applications/Ollama.app ]; then open -a Ollama
  else mkdir -p "$HOME/.ollama"; nohup "$OLLAMA" serve >"$HOME/.ollama/serve.log" 2>&1 & fi
  for _ in $(seq 30); do server_up && break; sleep 1; done
  server_up || die "Ollama didn't start within 30 seconds. Try running 'ollama serve' yourself."
fi

INSTALLED=$("$OLLAMA" list 2>/dev/null | awk 'NR > 1 { print $1 }')
[ -n "$INSTALLED" ] || die "You don't have any models yet. Run 'bash install.sh' first."

# Menu entries: the models install.sh set up (by use, then light/medium/heavy), or every installed
# model if the installer hasn't recorded any.
TAGS=(); USES=(); LINES=()
if [ -r "$STATE_FILE" ]; then
  USE_COUNT=$(awk '{ print $1 }' "$STATE_FILE" | sort -u | wc -l)
  while read -r use tier tag; do   # a handful of lines
    printf '%s\n' "$INSTALLED" | grep -qxF "$tag" || continue
    case $tier in light) hint="fastest" ;; medium) hint="balanced" ;; *) hint="best quality, slowest" ;; esac
    label=$tier; [ "$USE_COUNT" -gt 1 ] && label="$use $tier"
    TAGS+=("$tag"); USES+=("$use"); LINES+=("$(printf '%-15s %-26s %s' "$label" "$tag" "$D$hint$N")")
  done < <(awk '{ o = ($2 == "light") ? 1 : ($2 == "medium") ? 2 : 3; print $1, o, $2, $3 }' "$STATE_FILE" | sort -k1,1 -k2,2n | awk '{ print $1, $3, $4 }')
fi
if [ ${#TAGS[@]} -eq 0 ]; then
  for tag in $INSTALLED; do TAGS+=("$tag"); USES+=(""); LINES+=("$tag"); done
fi

menu() { # draws LINES and lets the user move with the arrow keys; sets CHOICE to the selected index
  local sel=0 n=${#LINES[@]} key i
  trap 'tput cnorm 2>/dev/null; echo; exit 130' INT
  tput civis 2>/dev/null
  say "${B}Which model?${N} ${D}(arrow keys to move, Enter to start)${N}"
  while :; do
    for i in "${!LINES[@]}"; do
      if [ "$i" = "$sel" ]; then printf '\r\033[K%s> %s%s\n' "$C" "${LINES[$i]}" "$N"
      else printf '\r\033[K  %s\n' "${LINES[$i]}"; fi
    done
    IFS= read -rsn1 key </dev/tty
    case "$key" in
      "") break ;;   # Enter
      $'\033')       # arrow keys arrive as ESC [ A / ESC [ B
        read -rsn2 -t 1 key </dev/tty
        case "$key" in "[A") sel=$(( (sel + n - 1) % n )) ;; "[B") sel=$(( (sel + 1) % n )) ;; esac ;;
      k) sel=$(( (sel + n - 1) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      [1-9]) [ "$key" -le "$n" ] && sel=$(( key - 1 )) ;;
    esac
    printf '\033[%dA' "$n"
  done
  tput cnorm 2>/dev/null; trap - INT
  CHOICE=$sel
}
menu
MODEL=${TAGS[$CHOICE]}
[ -n "$MODE" ] || { [ "${USES[$CHOICE]}" = coding ] && MODE=claude || MODE=chat; }

if [ "$MODE" = claude ]; then
  command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] ||
    die "Claude Code isn't installed. Run 'bash install.sh --use coding' to install it, or use --chat."
  say "Starting Claude Code with $MODEL in $(pwd)"
  exec "$OLLAMA" launch claude --model "$MODEL"
fi
say "Chatting with $MODEL. Type /bye to stop."
exec "$OLLAMA" run "$MODEL"
