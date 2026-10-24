# Node Palette / Add Graph Parity Design

## Goal

Make the left node palette expose the same usable graph node types in the same
order as the existing `Add Graph` menu. Remove internal/test-only nodes without
maintaining a second blacklist. Polish only the palette search and its top-edge
alignment without changing the shared project theme.

## Single Source Of Truth

The existing `Add Graph` menu rules remain authoritative:

- registered graph definitions;
- `importance_chain` allowlist;
- menu `skip` values;
- single-input suppression;
- `name_groups` ordering followed by remaining allowed definitions.

A pure shared catalog helper will produce the ordered definitions. Both
`cmenu.gd` and `node_palette.gd` will consume that helper. The palette must not
append every registered graph type after the canonical sequence.

## Palette Rendering

The palette keeps its current scrollable image-preview presentation and drag
behavior. Entries are rendered in the exact flattened order returned for
`Add Graph`. Search filters this canonical list without reordering it.

## UI Changes

- Copy the `Add Graph` search styles as independent resources.
- Apply a palette-only corner radius override to those duplicated
  `StyleBoxFlat` resources.
- Never mutate `theme_base.tres`, `theme_headers.tres`, the Add Graph scene, or
  the source styleboxes.
- Calculate the palette top inset from the live bottom edge of
  `fg/ColorRect`, eliminating the fixed one-pixel gap and following future top
  bar size changes.

## Compatibility

The implementation uses Godot scene geometry and theme overrides only. It has
no OS-specific input, filesystem, or rendering branches, so the same project
code is used by macOS and Windows exports.

## Verification

- Catalog tests prove unlisted/test definitions are excluded.
- Parity tests prove Add Graph and palette receive the same ordered type IDs.
- Scene tests prove palette style duplication and local corner radius.
- Geometry tests prove the live top bar bottom edge is used.
- Run the existing Godot test suite, macOS project launch, and Windows export
  validation.
