# Node Palette Drag-and-Drop Design

## Goal

Add a fixed, scrollable node palette to the graph editor. The palette shows the existing rendered node previews and lets users drag a node onto the graph. The existing context menu remains available.

## Source Of Truth

`scripts/graph_manager.gd` remains the only registry and factory for graph nodes:

- `graph_types` defines constructible node types.
- `graph_buttons` exposes localized display metadata.
- `get_graph()` remains the only node-instantiation path.
- `importance_chain` controls the preferred display order.

The palette must not contain a manually maintained type-to-scene or type-to-icon mapping. A new registered graph type appears automatically unless it is explicitly hidden by the palette visibility policy.

## Components

### Node palette catalog

`scripts/node_palette_catalog.gd` converts registry metadata into stable palette entries. It owns only generic conventions:

- icon path: `node_icons/Icon<TypeName>.png`;
- localized title selection;
- preferred ordering followed by newly discovered types;
- explicit hidden-type filtering;
- fallback metadata when an icon is missing.

### Palette UI

`scenes/node_palette.tscn` is a screen-space `CanvasLayer` with a fixed left panel and a `ScrollContainer`. `scripts/node_palette.gd` rebuilds its contents from the catalog at startup and after a language change. Each item is created from `scenes/node_palette_item.tscn`; the scene contains no graph-specific cards.

### Drag and drop

Palette items use Godot's native Control drag API. The drag payload contains a marker and the stable graph type id. A transparent full-screen drop surface is enabled only while a palette drag is active, so normal graph input is unaffected.

On a valid drop, the palette calls `graphs.create_graph_at_screen_position()`. That helper validates the type, delegates to `get_graph()` and centers the resulting graph under the cursor after converting screen coordinates through `glob.screen_to_world()`.

### Preview generation

The existing preview logic is retained but made deterministic and callable as an explicit developer action. It iterates the live registry and writes every preview using the same path convention consumed by the palette. Preview generation never runs during normal application startup.

## Error Handling

- Unknown graph type: reject the drop without creating a node.
- Missing preview: show a generated fallback card with node title and outline color.
- Drop outside the graph workspace: cancel without side effects.
- Duplicate input blocked by current graph policy: hide or disable the palette item using the same availability rule as the existing menu.

## Verification

- Catalog tests cover ordering, localization, hidden types, automatic discovery and icon naming.
- Drag payload tests reject malformed or unknown data.
- A Godot smoke test verifies that the palette scene builds without manually declared graph cards.
- Manual QA covers mouse and trackpad scrolling, drag cancellation, zoomed/panned graph placement and unchanged context-menu creation.

## Non-Goals

- Removing or redesigning the context menu.
- Adding node search, favorites or category management.
- Changing graph serialization or node scene implementations.
