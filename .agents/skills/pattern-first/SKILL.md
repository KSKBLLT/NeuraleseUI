---
name: pattern-first
description: Use before writing or changing any feature, UI element, scene, or behaviour in a Godot project, including the main Neuralese repo and prototype projects under D:\NRLSE\nnets\prototypes. Requires surveying how the codebase already solves every concern the change touches (controls, text and languages, input, layout, styling, windows, state, tests), presenting a reuse map, and getting the user's approval before any code is written.
---

# Pattern first

The codebase this skill serves is large, partly undocumented, and in many places replaces Godot's own features with its own systems. Code written from general Godot knowledge therefore tends to compile, look reasonable, and not fit: it skips the project's localization, bypasses its input handling, adds a second kind of button, or picks a colour that the neighbouring panel defines differently.

The rule of this skill: **every concern a change touches is answered from the code before code is written.** General knowledge suggests where to look; it never supplies the answer.

This skill comes before planning. Its reuse map is the input to `superpowers:writing-plans` or to any plan, not a replacement for one.

## 1. Name the concerns

Write down which concerns the task touches. The list below shows the kind of thing meant; it is not a checklist, and most tasks touch something that is not on it:

- what the user clicks, types into, drags or reads;
- user-visible text, and in which languages it must appear;
- how input reaches the control and what else may claim the same input;
- size, position, layout, behaviour on resize;
- colour, font, material, shader, animation timing;
- how a surface opens, closes, and blocks what is behind it;
- where state lives and how it is saved and restored;
- how the feature is tested.

## 2. Survey each concern

For each concern, find how the codebase already handles it.

1. **Start from the nearest analogue the user can already see**, not from a name you expect. Something on screen that behaves like the thing you are building: a control in the same panel, a window that opens the same way, a label that already changes language. Find it in the scene, then follow its scripts and resources.
2. **Read the analogue completely**: its scene file, every attached script, every resource it references. A search hit tells you where something is; only reading the file tells you how it works. Do not describe code you have not opened.
3. **Search for the effect, not for the API you would have used.** If the engine feature you expect returns no hits, the conclusion is that the project does not use that feature, not that the concern is unhandled. Search for the observable effect instead (strings in another language, a signal fired on a mode change, per-mode fields), and for code that does by hand what the engine feature would do.
4. **Expect several generations side by side.** Old and new solutions to the same concern often coexist. Find all of them, then decide which is current from evidence: last commit dates (`git log -1 --format=%as -- <file>`), comments that call something legacy, design documents, and which variant the most recent features use. If the evidence does not settle it, ask.
5. **Verify every "nothing found" a second way.** Search tools differ in regex dialect, and scene files can reference a script by path or by uid. Before you state that something is unused or absent, confirm it with a different query, or by opening a file that would have to contain it.
6. **Read the project's guardrails first**: AGENTS.md or CLAUDE.md, lists of generated files, test conventions, and warning comments in the files themselves. They override this skill.

When they are connected, use the code-intelligence tools, which answer from how Godot resolves the project rather than from text: GodotLens (`gdscript_definition`, `gdscript_references`, `scene_state`, `project_config`, `scene_validate`) and Serena (`find_symbol`, `find_referencing_symbols`). Their blind spot is scene files: the GDScript language server does not see method names used in `.tscn` signal connections, so check scenes separately.

## 3. Present the reuse map, then wait

Before any code, show the user a table:

| Concern | What exists (file:line or scene path) | Read or inferred | Decision |
|---|---|---|---|

The decision is one of: reuse as is, copy and modify, extend, or new.

- **Copying and modifying comes before creating.** A new control is made by duplicating a configured neighbour, or by instancing the same base scene and changing its parameters. A new window is registered and opened the way an existing window of the same kind is. A parallel implementation needs a stated reason.
- **Values come from the nearest neighbour, not from taste**: sizes, paddings, colours, fonts, materials, animation timings. If the project has no central palette, the neighbour is the palette.
- **"New" states why nothing existing fits and what was checked.**
- **"Inferred" rows are open questions**, listed as such. Do not build on them until they are read.

Wait for the user's approval of the map. If the user changes a decision, update the map before writing code.

## 4. While writing

- Follow the conventions of the file you are editing (naming, comment language, how it connects signals, how it reaches autoloads), even where they differ from Godot's usual style.
- When the analogue does something unusual (polling instead of signals, a metadata key, a wrapper node, an English string used as a lookup key), keep doing the same thing unless the user decides otherwise. Unusual patterns in this codebase are often load-bearing.
- Do not refactor or "clean up" the components you reuse.

## 5. Prototypes

Prototype projects live under `D:\NRLSE\nnets\prototypes`, one Godot project each, and are later ported into the main repo. For a prototype, the codebase to survey is the main repo, because that is where the result has to fit.

- Bring real components into the prototype by copying their files from the main repo, never by writing look-alikes. Copy the dependencies the component actually uses; where one is too large to bring along, replace it with the narrowest stub that satisfies the calls made, and record it.
- Keep a `PROVENANCE.md` in the prototype: every copied file with its source path and the main-repo commit, every stub and what it replaces, every deliberate deviation. Porting back should be mechanical.
- New code in a prototype follows the main repo's conventions, so it can be moved without being rewritten.

## Reference

`references/neuralese-landmarks.md` records what one survey of the main repo found, including traps that cost time. Use it to orient yourself, not as the list of places to look: it is incomplete by design and goes stale. Run the survey regardless. When the code disagrees with the reference, the code is right, and the reference should be corrected.
