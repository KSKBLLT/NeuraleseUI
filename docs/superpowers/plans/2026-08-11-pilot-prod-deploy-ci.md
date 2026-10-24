# Pilot and Production Deploy CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create separate pilot and production deployment branches that automatically test Neuralese and produce traceable Windows and macOS artifacts.

**Architecture:** Keep `main` as protected canonical history and use `pilot-deploy` and `prod-deploy` only as promotion targets. Reuse the existing Windows pipeline, add an equivalent macOS artifact pipeline, and keep public release publication behind the existing manual release workflows.

**Tech Stack:** GitHub Actions, Godot 4.7.1, Python 3.11/pytest, PowerShell, Rust/Tauri, macOS `codesign`/`hdiutil`.

## Global Constraints

- Automatic deploy builds have `contents: read` and cannot publish GitHub Releases.
- Every artifact name contains `github.ref_name` and `github.sha`.
- Windows and macOS pipelines run release, integration, and Godot checks before uploading artifacts.
- macOS builds are universal, ad-hoc signed, integrity checked, and explicitly marked as not notarized.
- Existing manual candidate and production-promotion workflows remain unchanged.

---

### Task 1: Encode the deployment contract

**Files:**
- Create: `tests/release/test_deploy_branch_workflows.py`

- [x] Write tests for branch triggers, verification commands, artifact naming, and read-only permissions.
- [x] Run the focused test and confirm it fails because the deploy workflows are missing.

### Task 2: Implement deploy builds

**Files:**
- Modify: `.github/workflows/build-windows-branch.yml`
- Create: `.github/workflows/build-macos-branch.yml`
- Modify: `.github/workflows/test-updater.yml`
- Modify: `.github/CODEOWNERS`

- [x] Add `pilot-deploy` and `prod-deploy` triggers to Windows and verification workflows.
- [x] Add the macOS 4.7.1 test, universal export, signature, dylib, DMG, and checksum pipeline.
- [x] Keep automatic workflows read-only and branch-qualified.

### Task 3: Document and verify promotion

**Files:**
- Create: `docs/deploy-branches.md`

- [x] Document the `dev -> integration -> pilot-deploy -> prod-deploy` flow and the role of `main`.
- [x] Run focused and complete release tests plus workflow syntax checks.
- [ ] Commit and push the same verified commit to both deployment branches.
- [ ] Confirm GitHub Actions started for Windows, macOS, and updater verification.
