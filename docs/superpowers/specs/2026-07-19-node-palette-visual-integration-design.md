# Node Palette Visual Integration Design

## Goal

Make the generated node palette feel like a native part of Neuralese: a compact scrollable strip of node previews, with no card chrome, duplicate labels, blue drag outline, or camera input leaking through the panel.

## Existing UI Reuse

- The palette background reuses the shader material and instance parameters from `fg/ColorRect` in `scenes/fg.tscn`.
- The search field copies the resolved theme, style boxes, font and colors from `WIN_GRAPH/menus/add_graph/Label2`.
- The palette keeps the existing catalog, registry and drag/drop creation path. No node type mapping is duplicated.

## Item Presentation

Each item is a transparent control containing only the generated node preview. The localized node name remains available as a tooltip and as a fallback when an icon is missing, but is not rendered below every preview. Hovering smoothly interpolates the preview to a subtle larger scale without changing container layout.

The drag preview is the same unframed image. The drop surface remains responsible for validating workspace bounds but draws no selection rectangle.

## Input Isolation

While the pointer is over the expanded palette or its reopen button, the palette owns the existing `menu_inside` layer and registers itself in `glob.scroll_imp`. This lets the `ScrollContainer` consume wheel input while stopping graph zoom and trackpad pan.

Middle-button camera dragging must also honor `_can_user_navigate()`. Leaving or collapsing the palette releases both blockers, including during tree teardown.

## Verification

- Scene tests assert transparent items, absent duplicate titles, tooltip fallback and unframed drag previews.
- Input tests assert palette scroll blocking and middle-button camera blocking.
- The full Godot test suite catches parse and integration regressions.
- A local visual run verifies blur reuse, scrolling, hover interpolation and drag/drop behavior.
