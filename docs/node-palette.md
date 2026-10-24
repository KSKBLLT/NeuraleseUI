# Node Palette

The graph editor builds the left node palette from `graphs.graph_types` and `graphs.graph_buttons` at runtime. Adding a registered graph type does not require editing the palette scene or maintaining a separate type-to-icon map.

The header filters nodes by localized title or stable type id. The arrow button collapses the palette without changing graph camera state; the remaining edge button restores it. Pointer input over the palette occupies the existing `menu_inside` interaction layer, so dragging its scrollbar cannot start a graph selection rectangle.

## Generate previews

Preview generation is an explicit developer action and never runs during normal startup.

Generate every registered node preview:

```bash
GODOT_BIN=/path/to/godot bash tools/generate_node_icons.sh
```

Generate selected previews into a temporary directory:

```bash
GODOT_BIN=/path/to/godot bash tools/generate_node_icons.sh \
  --node-icon-types=layer,input_1d \
  --node-icons-output=/tmp/neuralese-node-icons
```

The generator derives each filename from its stable type id. For example, `input_1d` becomes `node_icons/IconInput1d.png`. Node previews always use the original English UI so that documentation and the palette match the application. It restores camera state and removes temporary nodes when complete.

## Manual QA

1. Open the graph workspace and scroll the node palette with a mouse wheel and a trackpad.
2. Drag several previews onto empty graph space at different camera zoom levels.
3. Drop a preview over the palette and top bar; no graph should be created.
4. Cancel a drag and confirm no temporary graph remains.
5. Create a node from the existing context menu to verify that flow still works.
6. Search by a display title and a type id, then clear the query and confirm the full catalog returns.
7. Collapse and reopen the palette; graph position and zoom must remain unchanged.
8. Drag the palette scrollbar and confirm no graph selection rectangle appears.
