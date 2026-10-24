# Multipurpose Dialog Design

## Goal

Add one reusable Neuralese dialog that renders trusted configuration data into the same visual language as the existing login, signup, project creation, and Axon windows. Use it first to ask before downloading an available application update.

## Visual contract

- `MultipurposeDialog` extends the existing `SplashMenu` lifecycle so blur, focus, camera locking, opening animation, outside-click behavior, and closing animation remain consistent.
- The scene reuses `scenes/splash.tres` for the window surface, `resources/theme_base.tres` and `resources/theme_headers.tres` for typography and rich text, the bundled JetBrains fonts, and `scenes/BaseBComponent.tscn` for every action button.
- Header icons come only from existing `game_assets/icons` resources. The default is `warn.png`; update prompts use `download.png`. No new textures, shaders, colors, fonts, or button implementations are introduced.
- The body uses a scrolling `RichTextLabel`. The dialog clamps requested dimensions to the current viewport, preserving margins on small screens.

## Configuration and result contract

The caller passes a `Dictionary` that is also valid JSON:

```gdscript
{
    "id": "update_available",
    "title": {"en": "Update available", "ru": "Доступно обновление", "kz": "Жаңарту қолжетімді"},
    "body": "Version **1.0.8** is ready.",
    "format": "markdown",
    "icon_path": "res://game_assets/icons/download.png",
    "size": {"width": 480, "height": 280},
    "dismiss_on_escape": true,
    "dismiss_on_outside_click": false,
    "buttons": [
        {"id": "download", "text": {"en": "Download", "ru": "Скачать", "kz": "Жүктеу"}, "style": "primary"},
        {"id": "later", "text": {"en": "Later", "ru": "Позже", "kz": "Кейін"}, "style": "secondary"}
    ]
}
```

`title`, `body`, and button `text` accept either a string or an `en`/`ru`/`kz` dictionary. Missing locale entries fall back to English, then the first available string.

The awaited API returns only data:

```gdscript
{"dialog_id": "update_available", "action": "download"}
```

No configuration field accepts a `Callable`, script, node path, remote texture, or executable action. `icon_path` must be an existing PNG under `res://game_assets/icons/`. Duplicate active dialog IDs return the existing dialog instead of creating stacked copies.

## Text rendering

The dialog supports plain text and a safe Markdown subset: paragraphs, line breaks, bold, italic, inline code, unordered lists, and HTTP/HTTPS links. A dedicated pure formatter escapes BBCode first and then emits only the supported tags. Unknown Markdown remains visible as plain text; raw BBCode from a server cannot create Godot tags.

## Update flow

`UpdateManager` keeps `GET /check` and remains compatible with the current payload:

```json
{"version":"1.0.8","d_req":true,"exe_url":"download"}
```

It also accepts an additive platform-aware payload:

```json
{
  "version": "1.0.8",
  "d_req": true,
  "notes_markdown": "Bug fixes and performance improvements.",
  "mandatory": false,
  "downloads": {
    "windows": {"url": "https://example/Neuralese.exe", "sha256": "..."},
    "macos": {"url": "https://example/Neuralese-Setup-macOS.zip", "sha256": "..."}
  }
}
```

Versions are compared numerically by dot-separated components, so `1.0.10` is newer than `1.0.9`. The update prompt appears only for a newer version with `d_req=true`. Nothing downloads before the user chooses `download`.

- Windows: use the current streamed download and replacement script, with optional SHA-256 verification when supplied.
- macOS and Linux: open the platform installer URL in the default browser. The legacy `exe_url` is never offered outside Windows.
- `later` closes the dialog and continues startup.
- Malformed responses, unsupported URL schemes, absent platform URLs, and network failures are logged and do not interrupt application startup.

## Public API

`ui_manager.gd` exposes:

```gdscript
func show_dialog(spec: Dictionary) -> SplashMenu
func show_dialog_and_get_result(spec: Dictionary) -> Dictionary
```

Both methods use the existing splash container and the dialog's typed `action_selected` signal. Existing named splash APIs and `ResultEmitter` remain unchanged.

## Verification

- Pure headless tests cover configuration defaults and validation, locale fallback, Markdown escaping/conversion, semantic version comparison, platform URL selection, and legacy payload compatibility.
- Scene-level tests instantiate the dialog and verify original material/theme/button resources, dynamic button count, action result, duplicate-ID handling, viewport clamping, and dismissal policy.
- A manual smoke run checks the real opening/closing animation, scrolling long content, keyboard focus, and update prompt behavior.
- Existing macOS YAML GDExtension and built-in binary scene errors are baseline repository issues and are reported separately; they are not modified by this feature.

## Delivery constraints

- Work is isolated on `codex/multipurpose-dialog` from current `origin/main`.
- Do not migrate existing login, signup, project creation, or Axon windows in this change.
- Do not modify the backend repository or push the branch without explicit approval.
