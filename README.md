# Local coding-model installer (Ollama)

Detects your hardware, installs or updates [Ollama](https://ollama.com) and
[Claude Code](https://code.claude.com), and downloads three local coding models sized for your machine:

| Tier | What it's for |
|---|---|
| **light** | Quick questions, explanations and autocomplete (fastest) |
| **medium** | Everyday coding: writing functions, fixing bugs, reviews |
| **heavy** | The strongest model that fits comfortably, for hard problems and agent work |

Works on macOS, Linux and Windows. The model list lives in `models.txt`, so you can update it without
touching the scripts.

## Run it

macOS / Linux:

```bash
./install.sh
```

Windows (PowerShell 5.1 or newer):

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Keep `models.txt` in the same folder as the script. Start with `--dry-run` to see what it would do.

## Flags

| Flag | What it does |
|---|---|
| `--tier <tiers>` | Which models to install: `light`, `medium`, `heavy` or `all` (default: `all`). Combine with commas, e.g. `--tier light,medium`. `low`, `mid` and `high` also work. |
| `--budget <GB>` | Skip detection and use this memory budget |
| `--dry-run` | Detect hardware and print the plan; changes nothing |
| `--yes` | Don't ask for confirmation |
| `--no-context` | Don't change Ollama's context-window setting |
| `--no-claude` | Don't install or update Claude Code |

## What it does

1. **Works out a memory budget**, meaning how much memory a model can realistically use:
   - Apple Silicon Mac: 75% of unified memory (macOS only lets the GPU use part of it).
   - NVIDIA GPU: VRAM of the largest card (`nvidia-smi`).
   - AMD GPU on Linux: VRAM from `rocm-smi`.
   - AMD/Intel GPU on Windows: VRAM from the display driver's registry entry. Adapters reporting
     under 2 GB (typical integrated graphics) count as no GPU.
   - Intel Mac or no GPU: 50% of system RAM, with a warning that it will be slow.
2. **Picks a row from `models.txt`**: the highest row whose minimum is at or below your budget.
   Without a GPU, a 16 GB-or-higher row is dropped one row, because big models on a CPU are very
   slow. This doesn't apply when you pass `--budget`.
3. **Checks each tag exists** on ollama.com and gets its download size. On Apple Silicon it uses
   the MLX build of a model (for example `qwen3.8:27b-mlx`) when one is published, because it runs
   faster on Mac.
4. **Installs Ollama, or updates it to the latest release** (checked on GitHub), asking first. Press
   Enter to accept. New models often need a recent Ollama, and version 0.14.0 or newer is required
   for Claude Code.
   - macOS: Homebrew if Ollama came from Homebrew (or if it's missing and Homebrew is installed).
     Otherwise it downloads the official app from ollama.com, checks Apple's signature, quits the
     running app, swaps the new one into `/Applications` and reopens it. The old app is kept in a
     temporary folder, not deleted.
   - Linux: the official install script, which uses sudo.
   - Windows: winget, or the signed official installer if winget is missing.

   Then it starts the Ollama server if it isn't running.
   **Then Claude Code**, which `ollama launch claude` starts. If it's missing, the script offers to
   install it with the official installer (`curl -fsSL https://claude.ai/install.sh | bash`, or
   `install.ps1` on Windows). If it's installed, the script asks before updating it with
   `claude update` (or `brew upgrade` / `winget upgrade` if it came from Homebrew or WinGet).
5. **Downloads all three models by default** (or only the tiers named with `--tier`), after one
   confirmation. It skips models you already have and stops if free disk space is less than the
   downloads plus 10 GB. If one download fails, it continues with the others and lists the
   failures at the end. It never deletes models.
6. **Raises the context window** (`OLLAMA_CONTEXT_LENGTH`) from Ollama's default of 4096 tokens to
   32768, or 65536 when the budget is 28 GB or more, asking first:
   - macOS: `launchctl setenv`, plus an optional line in `~/.zshrc`. Restart the Ollama app afterwards.
   - Linux: a systemd drop-in at `/etc/systemd/system/ollama.service.d/context.conf`, then a restart.
   - Windows: `setx`. Quit Ollama from the system tray and start it again.

Running the script again is safe: anything already done is skipped.

## Editing models.txt

Each line holds the minimum budget in GB, followed by the light, medium and heavy tags. `#` starts
a comment.

```
# min  light              medium             heavy
16     qwen2.5-coder:7b   gpt-oss:20b        qwen3.8:27b
44     qwen3-coder:30b    qwen3.8:27b        qwen3.8:27b-q8_0|qwen3.8:27b
```

- Separate fallbacks with `|`. The first tag that exists on ollama.com is used, and the script
  says when it falls back.
- Use any tag from `https://ollama.com/library/<model>/tags`.
- Rows can be in any order; add or remove rows freely.

## Using the models

```bash
ollama run qwen2.5-coder:7b
```

```bash
ollama launch claude
```

```bash
ollama rm <model>
```

The first command chats with a model in the terminal. The second starts Claude Code backed by a
local model (it asks you to pick one). The third removes a model you no longer want.
