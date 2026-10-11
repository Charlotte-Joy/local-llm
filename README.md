# local-llm

Run AI models on your own computer. local-llm detects your hardware, installs or updates
[Ollama](https://ollama.com), downloads three models sized for your machine and picked for what
you'll use them for, and gives you one command to start them:

| Use | Picked for |
|---|---|
| **coding** | Writing and fixing code, and coding agents. Also installs or updates [Claude Code](https://code.claude.com). |
| **writing** | Creative writing, editing and general chat |
| **vision** | Understanding images, screenshots and documents |

Each use gets three tiers: **light** (fastest), **medium** (balanced) and **heavy** (the strongest
model that fits comfortably). Works on macOS, Linux and Windows.

## Quick start

### macOS and Linux

1. Open a terminal (on a Mac: the **Terminal** app).
2. Go into this folder, for example:
   ```sh
   cd ~/Downloads/local-llm
   ```
3. Run the installer:
   ```sh
   bash install.sh
   ```
4. Answer the questions. Pressing Enter accepts the suggested answer.

### Windows

1. Open **PowerShell** (search for it in the Start menu).
2. Go into this folder, for example:
   ```powershell
   cd $HOME\Downloads\local-llm
   ```
3. Run the installer:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
4. Answer the questions. Pressing Enter accepts the suggested answer.

The installer asks what you'll mainly use the models for, shows what it will download and how big
it is, then asks before downloading. At the end it prints the names of the models it installed.
To see the plan without changing anything, add `--dry-run` to the end of the command in step 3.

## Using the models

Open a terminal in the folder you want to work in and run the launcher from this folder:

| System | Type |
|---|---|
| macOS or Linux | `bash ~/Downloads/local-llm/launch.sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File $HOME\Downloads\local-llm\launch.ps1` |

Use the arrow keys to pick **light**, **medium** or **heavy**, then press Enter. Coding models start
in Claude Code, working on the folder you're in; writing and vision models start a chat. Add
`--chat` or `--claude` to the command to choose for yourself.

You can also start Claude Code directly with `ollama launch claude` and pick a model from its list.

### Using a model directly in the terminal

If you'd rather talk to a model without Claude Code, these commands work the same on every system.
Replace `<model>` with a name the installer printed, such as `qwen3.5:4b`.

| To do this | Type |
|---|---|
| Chat with a model (type `/bye` to stop) | `ollama run <model>` |
| Ask about a picture (vision models) | `ollama run <model> "What's in this picture? <full path to the image>"` |
| See which models you have | `ollama list` |
| Remove a model you don't want | `ollama rm <model>` |

For pictures, use the image's full file path, such as `/Users/you/Pictures/photo.png` on a Mac or
`C:\Users\you\Pictures\photo.png` on Windows. Dragging the file into the terminal window types
its path for you.

Other apps that support Ollama can use these models too; Ollama runs at `http://localhost:11434`.

## Options

Add options to the end of the run command, for example `bash install.sh --use writing` or
`powershell -ExecutionPolicy Bypass -File .\install.ps1 --use writing`. They're the same on every system.

| Option | What it does |
|---|---|
| `--use coding\|writing\|vision` | What the models are for; skips the question (default: ask, Enter picks coding) |
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
2. **Asks what the models are for**, then picks a row from that section of `models.txt`: the
   highest row whose minimum is at or below your budget.
   Without a GPU, a 16 GB-or-higher row is dropped one row, because big models on a CPU are very
   slow. This doesn't apply when you pass `--budget`.
3. **Checks each tag exists** on ollama.com and gets its download size. On Apple Silicon it uses
   the MLX build of a model (for example `qwen3.8:27b-mlx`) when one is published and is at most 10%
   bigger, because MLX is Apple's machine-learning framework and runs faster on Mac. Some MLX builds
   are much bigger than the regular build and would no longer fit, so those are skipped.
4. **Installs Ollama, or updates it to the latest release** (checked on GitHub), asking first. New
   models often need a recent Ollama, and version 0.14.0 or newer is required for Claude Code.
   - macOS: Homebrew if Ollama came from Homebrew (or if it's missing and Homebrew is installed).
     Otherwise it downloads the official app from ollama.com, checks Apple's signature, quits the
     running app, swaps the new one into `/Applications` and reopens it. The old app is kept in a
     temporary folder, not deleted.
   - Linux: the official install script, which uses sudo.
   - Windows: winget, or the signed official installer if winget is missing.

   Then it starts the Ollama server if it isn't running, and restarts it if an update left the old
   version running.
5. **Installs or updates Claude Code** (coding only), which `ollama launch claude` starts. If it's
   missing, the script offers the official installer. If it's installed, the script asks before
   updating it with `claude update` (or `brew upgrade` / `winget upgrade` if it came from Homebrew
   or WinGet).
6. **Downloads all three models by default** (or only the tiers named with `--tier`), after one
   confirmation. It skips models you already have and stops if free disk space is less than the
   downloads plus 10 GB. If one download fails, it continues with the others and lists the
   failures at the end. It never deletes models.
7. **Raises the context window** (`OLLAMA_CONTEXT_LENGTH`) from Ollama's default of 4096 tokens to
   32768, or 65536 when the budget is 28 GB or more, asking first:
   - macOS: `launchctl setenv`, plus an optional line in `~/.zshrc`. Restart the Ollama app afterwards.
   - Linux: a systemd drop-in at `/etc/systemd/system/ollama.service.d/context.conf`, then a restart.
   - Windows: `setx`. Quit Ollama from the system tray and start it again.

Running the installer again is safe: anything already done is skipped.

## Editing models.txt

Keep `models.txt` in the same folder as the scripts. It has one section per use. A section starts
with `[name] description`; the description is what the menu shows. Each row holds the minimum
budget in GB, followed by the light, medium and heavy tags. `#` starts a comment.

```
[writing] Creative writing, editing and general chat
# min  light        medium       heavy
0      gemma3:1b    gemma3:4b    -
44     gemma4:26b   gemma4:31b   qwen3.8:27b-q8_0|qwen3.8:27b
```

- Separate fallbacks with `|`. The first tag that exists on ollama.com is used, and the script
  says when it falls back.
- `-` means no model for that tier.
- Keep each model under about 80% of its row's budget, so there's room for the context window.
- Use any tag from `https://ollama.com/library/<model>/tags`.
- Rows can be in any order; add or remove rows and sections freely. A new section shows up in the
  menu automatically.

The current picks come from independent benchmarks (Artificial Analysis, Vals.ai, LiveBench,
swebench.com, EQ-Bench and LMArena), fetched in October 2026; the top of `models.txt` lists which
were used for each section. Image generation isn't included because Ollama removed it in 0.32.6
and hasn't brought it back yet.
