# Working in neuralese-builder

Instructions for AI coding agents (Claude Code, Codex, Cursor). This is the
canonical file; `CLAUDE.md` imports it.

**Rule for this file:** every claim below is traceable to a file in this repo.
When a fact could go stale, this file points at the source of truth rather than
copying it. Keep it that way — if you add a section, cite the file it came from.

---

## Stack

- **Godot 4.7.1** — GDScript. CI installs 4.7.1; `project.godot` declares
  `config/features=PackedStringArray("4.7", "Forward Plus")`.
- **Python 3.11** + `pytest` for tooling, docs, and release tests.
- Desktop client. Backend API lives in a separate repo
  (`https://github.com/hex358/neuralese-api/`).

> README.md says "configured with 4.6 feature flags". That is **wrong** — it is
> 4.7. See "Known-stale docs" below.

---

## Build the builtin datasets first

The app ships every builtin dataset (`local_runtime/datasets/`), but
`cifar10/train.npz` is 170 MB, over GitHub's 100 MB limit, so git holds only
its `meta.json` (`.gitignore`). Build it once per checkout, before running or
building the app (downloads 162 MB from www.cs.toronto.edu):

```bash
local_runtime/python/python.exe local_runtime/tools/build_builtin_datasets.py
```

`local_runtime/tools/check_builtin_datasets.py` makes `build.ps1`, the
`tools/build_*.ps1` runtime builds, `tools/prepare_windows_installer_payload.ps1`
and the Windows workflows fail when a dataset is missing. Without it,
`tests/local_runtime/test_cifar10_training.py` skips its real-data test. Details:
`local_runtime/datasets/README.md`.

---

## Verify your work

Run these before claiming anything works. They are lifted verbatim from
`.github/workflows/` — the same commands gate every deploy build.

```bash
# Python suites (fast; run these first)
python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration -v

# Node registry consistency — fails if generated catalogs are out of date
python -m tools.node_dev check

# Godot headless test suite (needs a Godot 4.7.1 binary)
GODOT_BIN=/path/to/godot bash tests/godot/run_all.sh

# Generated node scenes validated inside Godot (slow, ~5 min)
python -m tools.node_dev godot-check --godot-bin "$GODOT_BIN" --timeout 300
```

### How the Godot suite actually decides pass/fail

`tests/godot/run_all.sh` does **not** use a test framework. Each entry in its
`TESTS=(...)` array is a `file:marker` pair. The script runs the file headless
and greps stdout for that exact marker string. **No marker printed = FAIL**, even
if the test logic passed.

So when you add a Godot test you must do both:

1. Make the script `print()` its exact marker (e.g. `PASS test_my_thing`).
2. Register `"test_my_thing.gd:PASS test_my_thing"` in the `TESTS` array.

A test file that exists but is not reachable from the array **never runs in CI**.
Before assuming a file is orphaned, check the two indirect paths: a `.gd` may be
the script attached to a registered `.tscn` (as
`test_interface_tour_launch.gd` is), and a `.gd` may be driven by a different
runner (`test_update_integration.gd` runs from
`tests/integration/run_update_integration.sh`).

Three files are currently reachable from neither: `test_auth_live.gd`,
`test_auth_device_live.gd`, `test_output_map_migration.gd`. The first two look
deliberately excluded — they appear to need live credentials — but nothing in
the repo records that, so treat the exclusion as unexplained rather than
intentional.

`GODOT_SKIP_TESTS` is a comma-separated skip list. Branch builds set
`GODOT_SKIP_TESTS="test_simulation_dataset_generator.gd"` because that test needs
a 3000-second timeout. `test-updater.yml` sets no skip list, so it runs all 63.

**The runner is fail-fast** — it `exit 1`s on the first failure, so every test
after that one is silently not run. A green log tail proves nothing about the
tests below the failure. When you fix a failing test, re-run the whole suite;
the next failure may have been hidden behind it.

### A stale `.godot/` cache fakes failures that CI never sees

`run_all.sh` imports only when `.godot/global_script_class_cache.cfg` is
**missing** — never when it is merely out of date. So after pulling work that
adds a `class_name`, your local cache silently lacks it and tests fail to parse:

```
Parse Error: Could not resolve external class member "..."
```

That is your cache, not the code. CI checks out fresh and always imports, so it
never reproduces. Before believing a local-only parse error, refresh:

```bash
"$GODOT_BIN" --headless --path . --import
```

### Nothing runs CI on `dev`

`test-updater.yml` triggers on `pull_request` and on pushes to `main`,
`pilot-deploy`, `prod-deploy`. The other workflows trigger only on the deploy
branches or `workflow_dispatch`. **No workflow runs on a push to `dev`** — so
`dev` can sit broken and unnoticed until someone opens a PR against it. It has
happened. If you land on a red `dev`, check whether the breakage is yours before
debugging your own change.

---

## Never hand-edit generated files

These are **overwritten** by the generator. Editing them directly is silently
discarded work:

- `scripts/generated/node_sources.gd`
- `scripts/generated/node_catalog.gd`
- `local_runtime/neuralese_local/generated_node_catalog.py`
- `node_defs/generated/`

**Source of truth is `node_defs/*.json`.** To change how a node registers, edit
the JSON declaration and regenerate:

```bash
python -m tools.node_dev generate   # rewrite catalogs from node_defs/*.json
python -m tools.node_dev check      # verify catalogs match declarations
```

CLI subcommands (`tools/node_dev/cli.py`): `list`, `inspect`, `discover`,
`validate`, `generate`, `check`, `new`.

Adding a node is a two-step flow: build the `.tscn` inheriting `BaseGraph` the
normal way, then register it with `python -m tools.node_dev new <name> --scene
res://scenes/<name>.tscn ...`. Titles, ports, and colors are extracted from the
scene — do not retype them. Run `inspect` on a similar existing node first and
reuse its patterns; the tool deliberately does not introduce a second UI
framework. Full docs: `tools/node_dev/README.md` (Russian).

---

## Autoloads

**Read `project.godot` `[autoload]` for the current list.** Do not trust any
prose list, including README's — it omits `events`, `local_runtime`, `luas`, and
`MCPGameBridge`.

Autoloads are globals available in every script (`web.request(...)`,
`glob.PILOT_MODE`, etc.). Their implementations live in `scripts/`.

---

## Network mode

Do **not** hardcode API URLs. Resolution lives in `scripts/network_mode.gd`:

| Mode | Trigger | HTTP root |
|---|---|---|
| Remote | **default** | `https://neuralese.asia/` |
| Localhost | `--local-api` | `http://127.0.0.1:8081/` |
| LAN | `--lan-api` | `http://<lan_ip>:8081/` |

Passed as Godot **user args** (after `--`), read via
`OS.get_cmdline_user_args()` in `scripts/glob.gd`.

> README.md claims the default is localhost on port **8000** and that you switch
> modes by editing `scripts/glob.gd`. Both are wrong: the default is Remote, the
> local port is **8081**, and the switch is a command-line flag.

---

## Branches and pull requests

**Open PRs against `dev`.** This is what the repo actually does, not what its
docs say — PRs #7 and #5 merged into `dev`; `origin/main` has zero merge commits
and every PR opened against it (#2, #3, #4, #9) is still open and stale.

Promotion path, from `docs/deploy-branches.md`:

```
dev -> integration -> pilot-deploy -> prod-deploy
```

`pilot-deploy` (school pilot builds) and `prod-deploy` (production builds) are
deployment triggers — pushing to them starts installer/DMG workflows. Never push
to them directly.

---

## Repo layout

| Path | What it is |
|---|---|
| `scripts/` | GDScript source, incl. all autoloads |
| `scenes/` | Godot scenes |
| `node_defs/` | **Node registry — the editable source of truth** |
| `tools/node_dev/` | Node generator CLI |
| `tests/` | `godot/`, `jasondocs/`, `release/`, `integration/`, `local_runtime/`, `node_dev/` |
| `local_runtime/` | Bundled Python runtime for offline training |
| `docs/` | Human docs; `docs/superpowers/` holds specs and plans |
| `JasonDocs/` | Per-node documentation, contract-tested by `tests/jasondocs/` |
| `addons/` | Third-party Godot plugins — do not modify |

---

## Known-stale docs

Treat these as unreliable; verify against the source before repeating them.

| Doc | Stale claim | Reality |
|---|---|---|
| `README.md` | "4.6 feature flags" | 4.7 (`project.godot`), CI pins 4.7.1 |
| `README.md` | Default API `127.0.0.1:8000`, switch in `glob.gd` | Default Remote; local is `:8081`; switch via `--local-api` in `network_mode.gd` |
| `README.md` | Autoload list | Incomplete — see `project.godot` |
| `docs/deploy-branches.md` | "`main` … pull-request base" | PRs merge into `dev`; main has 0 merges since 2025-08-10 |

---

## Conventions

- Some docs and code comments are in Russian (`node_defs/README.md`,
  `tools/node_dev/README.md`). Match the language of the file you are editing.
- `tests/jasondocs/` contract-tests documentation content — adding or renaming a
  node usually means updating `JasonDocs/` too, or those tests fail.
- Do not commit `local_runtime/.emulators/` (vendored third-party emulators) or
  root-level `*.tmp` files. Stage files by name; never `git add -A`.
