# macOS input support

## What changed

- Two-finger trackpad movement pans the graph canvas.
- Trackpad pinch gestures zoom the graph canvas.
- Existing Windows and Linux `Ctrl` shortcuts use `Command` on macOS.
- Redo supports both `Command+Y` and `Command+Shift+Z` on macOS.
- The UI follows the macOS display scale while keeping native HiDPI rendering enabled.
- The same platform-aware modifier is used by the built-in YAML editor.
- The macOS export preset builds a high-resolution universal application bundle and includes the YAML and Lua libraries.

## Implementation

Platform-specific input behavior is centralized in `scripts/platform_input.gd`. The graph camera handles native Godot `InputEventPanGesture` and `InputEventMagnifyGesture` events. Shortcut actions use Godot's `command_or_control_autoremap`, so Windows and Linux behavior remains unchanged.

## Manual check

1. Open a graph and move around it with a two-finger trackpad gesture.
2. Pinch to zoom in and out.
3. Confirm that dragging nodes still works and does not pan the canvas.
4. Check save, undo, redo, copy, paste, select all, duplicate and delete with `Command` shortcuts.
5. Open the YAML editor and confirm its `Command` shortcuts work as well.

## macOS build

Export the `macOS` preset from Godot. The resulting `Neuralese.app` is ready to be placed into the macOS installer payload.
