# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hermes Agent is a self-improving AI agent framework by Nous Research. It creates skills from experience, supports 200+ LLM models via OpenRouter/Anthropic/OpenAI, provides 19 messaging platform adapters, and runs anywhere (local, Docker, SSH, Modal, Daytona).

## Development Setup

```bash
# Activate venv (ALWAYS do this before running Python)
source venv/bin/activate

# Install with all extras
uv venv venv --python 3.11
uv pip install -e ".[all,dev]"

# Optional: browser tools
npm install
```

**User config:** `~/.hermes/config.yaml` (settings), `~/.hermes/.env` (API keys)

## Common Commands

```bash
# Run tests (excludes integration tests, uses xdist parallel by default)
python -m pytest tests/ -q

# Run specific test file
python -m pytest tests/test_model_tools.py -q

# Run specific test areas
python -m pytest tests/tools/ -q          # Tool tests
python -m pytest tests/gateway/ -q        # Gateway tests
python -m pytest tests/hermes_cli/ -q     # CLI tests

# Integration tests only (require API keys)
python -m pytest tests/ -m integration

# Run the CLI
hermes

# Diagnostics
hermes doctor
```

## Commit Style

Conventional Commits: `<type>(<scope>): <description>`

Types: `fix`, `feat`, `docs`, `test`, `refactor`, `chore`
Scopes: `cli`, `gateway`, `tools`, `skills`, `agent`, `install`, `security`

## Architecture

### File Dependency Chain

```
tools/registry.py  (no deps — imported by all tool files)
       ^
tools/*.py  (each calls registry.register() at import time)
       ^
model_tools.py  (imports tools/registry + triggers tool discovery)
       ^
run_agent.py, cli.py, batch_runner.py, environments/
```

### Core Classes

- **AIAgent** (`run_agent.py`) — Main conversation loop. `run_conversation()` is the full interface; `chat()` is the simple wrapper. Loop is synchronous: call LLM -> execute tool calls -> append results -> repeat until text response or budget exhausted.
- **HermesCLI** (`cli.py`) — Terminal UI via Rich + prompt_toolkit. Dispatches slash commands via `process_command()`.
- **SessionDB** (`hermes_state.py`) — SQLite with FTS5 full-text search for session persistence.
- **ContextCompressor** (`agent/context_compressor.py`) — Auto-summarization when approaching context limits.
- **Tool Registry** (`tools/registry.py`) — Central registry; tools self-register at import time.

### Config Loaders (three separate systems)

| Loader | Used by | Location |
|--------|---------|----------|
| `load_cli_config()` | CLI mode | `cli.py` |
| `load_config()` | `hermes tools`, `hermes setup` | `hermes_cli/config.py` |
| Direct YAML load | Gateway | `gateway/run.py` |

### Slash Command Registry

All commands defined in `COMMAND_REGISTRY` list of `CommandDef` objects in `hermes_cli/commands.py`. CLI, gateway, Telegram menu, Slack mapping, and autocomplete all derive from this single registry.

**Adding a command:** (1) Add `CommandDef` to `COMMAND_REGISTRY`, (2) Add handler in `cli.py`'s `process_command()`, (3) Optionally add gateway handler in `gateway/run.py`.

### Adding a Tool (3 files)

1. Create `tools/your_tool.py` — handler + schema + `registry.register()` call
2. Add import to `_modules` list in `model_tools.py`'s `_discover_tools()`
3. Add to `toolsets.py` — either `_HERMES_CORE_TOOLS` or a new toolset

All handlers MUST return a JSON string. Agent-level tools (todo, memory) are intercepted by `run_agent.py` before `handle_function_call()`.

### Adding Configuration

- **config.yaml options:** Add to `DEFAULT_CONFIG` in `hermes_cli/config.py`, bump `_config_version` to trigger migration
- **.env variables:** Add to `OPTIONAL_ENV_VARS` in `hermes_cli/config.py` with metadata (description, prompt, url, password, category)

## Critical Rules

### Profile-Safe Paths

**Always use `get_hermes_home()`** from `hermes_constants` for all file paths. Never hardcode `~/.hermes` or `Path.home() / ".hermes"`. Use `display_hermes_home()` for user-facing messages. Hardcoding breaks the multi-profile system.

```python
# GOOD
from hermes_constants import get_hermes_home
config_path = get_hermes_home() / "config.yaml"

# BAD — breaks profiles
config_path = Path.home() / ".hermes" / "config.yaml"
```

### Prompt Caching Must Not Break

Do NOT alter past context, change toolsets, reload memories, or rebuild system prompts mid-conversation. Cache-breaking causes dramatically higher costs. Only context compression may alter context.

### Cross-Tool Schema References

Tool schema descriptions must not mention tools from other toolsets by name. Those tools may be unavailable, causing hallucinated calls. Add dynamic cross-references in `get_tool_definitions()` in `model_tools.py`.

### Cross-Platform

Never assume Unix. Guard `termios`/`fcntl` with `ImportError`/`NotImplementedError` catches. Use `pathlib.Path` not string `/` concatenation. Handle Windows `cp1252` encoding for `.env` files.

### Testing

- Tests must not write to `~/.hermes/` — the `_isolate_hermes_home` autouse fixture redirects to temp dir
- When mocking `Path.home()`, also set `HERMES_HOME` env var
- Do NOT use `simple_term_menu` for interactive menus (rendering bugs in tmux/iTerm2) — use `curses` instead
- Do NOT use `\033[K` (ANSI erase-to-EOL) in spinner/display code — leaks as literal text under prompt_toolkit's `patch_stdout`. Use space-padding.

### Skills vs Tools

Most new capabilities should be **skills** (instructions + shell commands + existing tools), not tools. Only create tools when you need custom Python integration, binary data handling, or streaming that can't go through the terminal.

- Bundled skills (`skills/`): broadly useful to most users
- Optional skills (`optional-skills/`): official but not universally needed
- Skills Hub: specialized/community contributions

### Code Style

PEP 8 with practical exceptions (no strict line length). Comments only for non-obvious intent. Catch specific exceptions. Use `logger.warning()`/`logger.error()` with `exc_info=True` for unexpected errors.
