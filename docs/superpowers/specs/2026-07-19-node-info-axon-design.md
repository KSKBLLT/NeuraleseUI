# Node Info and Axon Context Design

## Goal

Turn the existing node `Get info` popup into a useful, localized reference for every graph node and let the user ask Axon about the selected node in one action.

The feature must:

- show information for the node that opened the popup instead of the current static Input2D text;
- remove the unused bottom button;
- turn the top button into a localized `Ask Axon` action;
- open Axon and automatically send a localized question about the selected node;
- show a visual source line such as `From RunModel info` above the user message;
- keep that source line out of the API request;
- cover every active node and fail validation when a new node has no documentation.

## User Flow

1. The user opens a node context menu and selects `Get info`.
2. The info popup resolves the node ID from the node's `created_with` metadata.
3. The popup loads that node's title and documentation in the current interface language.
4. The popup displays one action, localized as:
   - English: `Ask Axon`
   - Russian: `Спросить Аксона`
   - Kazakh: `Аксоннан сұрау`
5. Pressing the action closes the info popup and opens Axon.
6. If the user is not authenticated, the existing login splash is shown first. The question is sent only after successful login.
7. Axon displays the outgoing question with a localized source line above it, then sends only the question text through the existing message stream.

Localized question templates:

- English: `What does {node} do in this context and overall?`
- Russian: `Что делает {node} в этом контексте и в целом?`
- Kazakh: `{node} осы контексте және жалпы не істейді?`

Localized source-label templates:

- English: `From {node} info`
- Russian: `Из описания {node}`
- Kazakh: `{node} сипаттамасынан`

The node name comes from the localized documentation title. It is not inferred from visible scene text.

## Source of Truth

The implementation must reuse `JasonDocs/<node_id>/node.json`. It must not add a second node-to-description mapping in GDScript.

`JasonDocs` already mirrors every entry in `GraphManager.graph_types` and separates data into:

- `generated`: scene-derived metadata owned by `python -m tools.jasondocs sync`;
- `docs`: authored, trilingual content preserved by the generator.

The UI reads the following fields dynamically:

- `docs.title`;
- `docs.summary`;
- `docs.operation`;
- `docs.ports` together with `generated.ports`;
- `docs.settings` together with `generated.settings`;
- `docs.compact.body` as a compact fallback.

All 21 active node documents will receive complete English, Russian, and Kazakh prose. Existing backend Axon node documentation is a factual reference for matching node types. Builder-only nodes are documented from their generated metadata and current scene behavior.

The JasonDocs generator continues to own only `generated`; manually authored `docs` content must survive every sync.

Because `JasonDocs` is intentionally hidden from Godot with `.gdignore`, the documentation tool also produces a compact derived artifact at `resources/node_info_catalog.json`. The runtime reads this generated catalog, and desktop export presets explicitly include it. Authors never edit the catalog directly; validation fails when it is missing or stale, so `JasonDocs` remains the only source of truth.

## Components

### NodeInfoCatalog

A focused GDScript service loads and validates JasonDocs at runtime. Its public interface accepts a node ID and language and returns a normalized view model:

- localized title;
- localized summary and operation;
- localized port rows;
- localized setting rows;
- Axon question;
- Axon source label.

Language lookup uses the requested language, then English, then generated title metadata. Missing optional rows are omitted. Unknown or malformed node documents return a generic localized fallback instead of crashing the menu.

The catalog contains localization templates for the UI action, question, and source label, but no per-node switch or `if/else` mapping.

### NodeInfoMenu

The existing `debug_info` menu receives a dedicated controller instead of static scene text.

Responsibilities:

- accept the selected `Graph` instance from `edit_graph.gd`;
- resolve its stable node ID from `created_with`;
- request a view model from `NodeInfoCatalog`;
- render safe BBCode into the existing RichTextLabel;
- expose only the `Ask Axon` button;
- delegate Axon navigation and sending without implementing chat logic.

The scene's `bottom_button` is removed. The top button remains in the existing visual position and uses the project's current button assets and interaction style.

### Axon Context Request

Axon receives a small structured local request containing:

- question text;
- source label;
- unique request ID.

`AIHelpMenu` consumes the request once whenever it is opened or reused. The request ID prevents duplicate sends if the splash is already present or its lifecycle methods run more than once.

The existing `send_message()` path remains the only API path. No API response format, backend payload shape, model provider, or Axon output behavior changes.

### Message Presentation

The user-message template gains an optional source label above the message body. It is hidden for ordinary messages and visible only for messages created from node info.

The label is presentation metadata. It is never concatenated with the question and never passed to `glob.update_message_stream()`.

## Rendering Rules

The info body is built from structured JasonDocs fields, not raw untrusted BBCode. Dynamic text is escaped before insertion. The body uses short sections suitable for the current popup:

1. summary;
2. what the node does;
3. inputs and outputs when present;
4. settings when present.

The popup keeps the existing Neuralese design. This task does not redesign the menu, resize the application, or alter graph interaction.

## Error Handling

- Missing `created_with`: show a generic localized unavailable message and disable `Ask Axon`.
- Unknown node ID: same fallback; log one actionable warning with the node ID.
- Missing current-language text: fall back to English.
- Invalid JSON: do not crash; show fallback and log the file path plus parse error.
- Login canceled or failed: keep Axon unopened and do not send a question.
- Repeated splash callbacks: request ID ensures one outgoing question.
- Axon network failure: use the existing chat error behavior; this feature does not create a second error path.

## Testing

### Automated

Add Godot tests that verify:

- every active `GraphManager.graph_types` ID has a readable JasonDocs document;
- every active node has non-empty title, summary, operation, and compact body in `en`, `ru`, and `kz`;
- every generated port and setting has a complete trilingual description;
- localization and English fallback work;
- question and source templates are correct in all three languages;
- the debug info scene has one action and no bottom button;
- the selected node ID produces its own content rather than Input2D content;
- an Axon context request is consumed once;
- the visual source label is not included in the text sent to the API.

Run existing Godot tests, JasonDocs validation, and the project's normal static checks so the feature cannot regress graph behavior.

### Manual

For at least one model node, one data node, and one training node:

1. open `Get info` and verify title/content match the selected node;
2. switch among English, Russian, and Kazakh and verify the popup and question language;
3. press `Ask Axon`, verify the source line and generated question;
4. repeat while logged out and cancel login, verifying nothing is sent;
5. reopen the same flow and verify only one message is sent per click.

## Non-Goals

- Changing Axon's response format or backend API.
- Sending extra graph JSON or node position data.
- Replacing JasonDocs or duplicating it in another registry.
- Redesigning the Axon window or the node context menu.
- Adding semantic routing, embeddings, or a second LLM request.

## Acceptance Criteria

The feature is complete when every active node displays correct localized information, `Ask Axon` sends exactly one localized question through the existing chat path, the source line is visible but absent from the API text, unauthenticated users follow the existing login flow, and all automated validation passes.
