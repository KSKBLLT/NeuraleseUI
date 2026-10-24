---
name: godot-tooling-setup
description: "Godot MCP/plugins installed 2026-10-10/11, and the traps each one hit (elicitation auto-decline, cached MCP config, LSP port)"
metadata:
  node_type: memory
  type: reference
  originSessionId: bfb82c48-ed08-45d8-810e-9e7dea3a0ab3
  modified: 2026-10-11T15:04:57.059Z
---

User-scope MCP: `godot` = Erodenn godot-mcp-runtime (39 tools), `godotlens` (LSP on 6005), `serena`. Plugins: superpowers, feature-dev, windows-computer-use. User skills: ~/.claude/skills/pattern-first (+ references/neuralese-landmarks.md), ~/.claude/skills/visual-qa. Drafts copy: D:\NRLSE\nnets\prototypes\_skill_drafts.

Traps:
- The Claude desktop app cannot show MCP elicitation prompts and auto-answers "declined". godot-mcp-runtime asks before run_project and before disk writes in run_script, so it needs env GODOT_MCP_DISABLE_ELICITATION=true (set; verified 2026-10-11: run_project + mkdir + save_png all succeed). "User declined" from that server never means the user declined.
- A session caches MCP server commands at start: /mcp Reconnect and auto-restart reuse the OLD command. Config changes need a session restart.
- run_script supports await across frames: per-frame viewport image + properties capture works (verified, 12 frames).
- Godot 4.7.2 at D:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe (also on PATH). Serena's Godot LSP port set to 6005 in ~/.serena/serena_config.yml.
- windows-computer-use pinned via settings env WCU_SOURCE (commit 8d367a86); its venv needs mcp<2.
- claude CLI not on PATH: C:\Users\Mike\AppData\Roaming\Claude\claude-code\<ver>\...\claude.exe.

Work layout: main repo D:\NRLSE\nnets\teachneurons; prototypes one Godot project each under D:\NRLSE\nnets\prototypes.
