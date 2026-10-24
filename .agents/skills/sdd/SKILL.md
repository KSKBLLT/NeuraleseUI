---
name: sdd
description: Spec-Driven Development (SDD) workflow for complex features, architectural refactors, and UI changes in Neuralese and prototype Godot projects. Use when planning or executing multi-step development to enforce visual contracts, data-driven interfaces, and test-first verification.
---

# Spec-Driven Development (SDD)

In Neuralese, non-trivial features follow a strict Spec-Driven Development process before code is written. This prevents visual divergence, broken contracts, and regressions across Godot versions and localizations.

## SDD Lifecycle

1. **Pattern Survey (`pattern-first`)**:
   - Survey nearest neighbour components in the codebase.
   - Map controls, localizations (`Loc` nodes / dictionaries), shaders, inputs (`glob.occupy`), and window lifecycle (`SplashMenu`).

2. **Design Spec (`docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`)**:
   - **Goal**: Clear, single-paragraph statement of the user-visible objective.
   - **Visual Contract**: Exactly which shaders (`splash.tres`, `block.gdshader`, etc.), themes (`theme_headers.tres`), and base scenes (`BaseBComponent.tscn`) are reused. Explicitly state what new visual elements are NOT introduced.
   - **Data & Result Contract**: Pure data APIs (JSON-compatible dictionaries), locale dictionaries (`en`, `ru`, `kz`), no raw execution leaks.
   - **Verification Contract**: Concrete automated tests (`tests/godot/`, `pytest`) and visual QA capture checklist.

3. **Implementation Plan (`docs/superpowers/plans/YYYY-MM-DD-<feature>-plan.md`)**:
   - Break work down into discrete, bite-sized tasks with explicit verification steps after each task.

4. **Execution & Verification (`visual-qa`)**:
   - Follow the plan step-by-step.
   - Run verification tests after each step.
   - Perform Visual QA across resolutions and languages (`en`, `ru`, `kz`) before declaring done.
