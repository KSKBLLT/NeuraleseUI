# Node Palette Toggle Animation Design

## Goal

Replace the instant node-palette visibility switch with a short, polished animation that matches Neuralese's restrained interface and does not affect graph navigation.

## Motion

- Duration: 0.22 seconds.
- Transition: cubic ease-out when opening and cubic ease-in when closing.
- The complete palette slides horizontally between its visible position and a position just outside the left edge.
- Opacity follows the same tween, reaching 1 when open and 0 when closed.
- The reopen button stays hidden while the palette moves. It appears only after closing finishes and disappears before opening starts.
- Repeated clicks interrupt the current tween and animate from the current visual state, avoiding jumps or overlapping tweens.

## State And Input

`set_collapsed` remains the public state API. The method updates the target state, releases search focus when closing, cancels any active animation, and starts a new tween from the current position and opacity.

The panel remains visible while animating so it can be drawn. It becomes hidden only after a completed close. Geometry and drop-surface boundaries use the target collapsed state immediately, preventing the hidden panel from blocking graph interaction.

Initialization applies the open state without animation. Resize events preserve the current open or closed endpoint and do not create a new tween.

## Verification

- A focused Godot test verifies animation configuration, endpoint state, interruption safety, and initialization without animation.
- The complete Godot test suite must remain green.
- A manual run verifies that opening and closing are smooth and that the graph remains usable during and after the transition.

## Scope

Only the node palette toggle is changed. Node rendering, search, drag-and-drop, graph camera behavior, and shared project styles remain unchanged.
