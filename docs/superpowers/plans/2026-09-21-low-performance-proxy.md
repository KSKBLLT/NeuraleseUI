# Low-performance Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and verify a reproducible Godot 4.7.1 llvmpipe proxy matching Yernar's measured low-end environment.

**Architecture:** Runtime artifacts live outside the product under `.superpowers/low-perf-proxy`. A PowerShell entry point delegates to a Linux shell launcher inside WSL; the shell launcher pins the Mesa Vulkan ICD, CPU affinity, Mobile renderer, resolution, user-data directory, and logs. Verification parses both system limits and the renderer actually reported by Godot.

**Tech Stack:** PowerShell 5.1, WSL2 Ubuntu 24.04, Bash, Mesa lavapipe Vulkan, Godot 4.7.1.

**Spec:** `docs/superpowers/specs/2026-09-21-low-performance-proxy-design.md`

## Global Constraints

- Do not modify application source or existing user changes.
- Use the official Godot 4.7.1 Linux binary.
- Fail closed if Godot does not report llvmpipe.
- Preserve the existing global WSL limits: 4 CPUs, 4 GB RAM, no swap.
- Keep runtime files and user data in `.superpowers/low-perf-proxy/`.

## Review Focus

- WSLg silently selects D3D12 instead of lavapipe: verification must reject it.
- Missing Linux binary or wrong Godot version: verification must reject it.
- Shell/PowerShell path conversion with spaces: launch must use resolved paths safely.
- Torture profile accidentally uses four cores: diagnostics must report the two-core affinity.
- Existing app user data contaminates the run: launcher must use an isolated data directory.

---

### Task 1: Install and launch the verified proxy

**Files:**
- Create: `.superpowers/low-perf-proxy/test-proxy.ps1`
- Create: `.superpowers/low-perf-proxy/run.ps1`
- Create: `.superpowers/low-perf-proxy/run-wsl-llvmpipe.sh`
- Create: `.superpowers/low-perf-proxy/Godot_v4.7.1-stable_linux.x86_64`

**Interfaces:**
- Consumes: WSL distribution `Ubuntu`, Mesa ICD `/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`, current repository path.
- Produces: `run.ps1 -Profile yernar|torture [-VerifyOnly]` with a nonzero exit code on any environment mismatch.

- [ ] **Step 1: Write the failing smoke test**

The test invokes `run.ps1 -VerifyOnly`, requires a zero exit code, and asserts
that its output contains Godot `4.7.1`, `llvmpipe`, Mobile, `1280x720`, `4 CPU`,
`4 GB`, and `0 swap`.

- [ ] **Step 2: Run the smoke test and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .superpowers/low-perf-proxy/test-proxy.ps1`

Expected: FAIL because `run.ps1` and the Linux Godot binary do not exist.

- [ ] **Step 3: Install dependencies and implement the minimal launchers**

Install `vulkan-tools` in Ubuntu, download and extract the official Godot
4.7.1 Linux binary, and create the two launchers. The Linux launcher exports
both `VK_DRIVER_FILES` and legacy `VK_ICD_FILENAMES`, runs through `taskset`,
and passes `--rendering-method mobile --rendering-driver vulkan --resolution 1280x720`.

- [ ] **Step 4: Run the smoke test and verify GREEN**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .superpowers/low-perf-proxy/test-proxy.ps1`

Expected: PASS with verified llvmpipe and all fixed limits printed.

- [ ] **Step 5: Run a real short project probe**

Run: `.superpowers/low-perf-proxy/run.ps1 -Profile yernar -ProbeFrames 5`

Expected: Godot exits successfully and the saved log identifies llvmpipe with
the Mobile renderer; no hardware GPU name is accepted.

- [ ] **Step 6: Verify torture affinity**

Run: `.superpowers/low-perf-proxy/run.ps1 -Profile torture -VerifyOnly`

Expected: PASS and diagnostics report CPU set `0-1`.
