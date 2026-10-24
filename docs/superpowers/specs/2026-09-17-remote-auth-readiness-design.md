# Remote Auth Readiness Design

## Goal

Keep startup onboarding independent from network authentication while making every remote feature behave safely when an access token has not arrived yet.

The feature must:

- show the local "Who is working now?" and tutorial prompt without waiting for authentication;
- treat local profile identity and remote authenticated session as separate states;
- show one localized `ui.error` when a user starts a remote-only action without a bearer token;
- never queue or automatically replay that rejected user action;
- silently skip background remote work while authentication is unavailable;
- preserve local projects, local datasets, local training, local inference, simulations, and built-in projects;
- prevent protected REST or WebSocket traffic from leaving the process without a bearer token;
- make future unclassified endpoints and transport bypasses fail automated checks.

## State Model

The application has two independent facts:

1. **Local identity is selected.** The application knows which child or teacher is using the device. This is sufficient for onboarding, local personalization, and local work.
2. **Remote session is ready.** `cookies.has_auth_session()` is true and `cookies.get_bearer_auth_header()` contains a non-empty `Authorization: Bearer ...` value. This is required for protected backend operations.

`glob.logged_in()` remains a compatibility/UI identity concept. It must not authorize network traffic and must not be used as the readiness check for Axon, classrooms, cloud projects, or remote model operations.

## Request Classes

Every outbound request belongs to exactly one class:

- **Public:** health checks, updater downloads, legacy login/create-account entry points, and authentication bootstrap/refresh requests.
- **Protected:** Axon, classroom operations, cloud project CRUD, remote datasets, remote export, remote training, remote inference, and remote dataset streaming.
- **External public URL:** an explicit absolute URL used by the updater or LAN health probe. These do not receive a Neuralese bearer token.
- **Approved raw transport:** authentication bootstrap, local OAuth callback, and transcription code that cannot currently use the shared wrapper. These files are allowlisted and audited.

An internal Neuralese route absent from the endpoint catalog is unknown and is denied. Absolute third-party URLs are allowed only through approved call sites and never receive the Neuralese bearer header.

## Endpoint Source of Truth

`resources/network_endpoint_policy.json` is the machine-readable source of truth for:

- REST aliases and their canonical paths;
- public and protected REST routes;
- WebSocket aliases and protected WebSocket routes;
- approved files containing raw network primitives;
- approved dynamic absolute-URL call sites.

`RemoteEndpointPolicy` loads and validates this catalog for runtime decisions. The Python boundary audit loads the same file, so runtime behavior and CI cannot drift into two independently maintained lists.

## Interactive Behavior

An interactive remote entry point calls one shared guard before changing UI or local state. If no bearer session exists, the guard calls `ui.error` once and returns `false`.

Localized copy:

- Russian: `Подключение к Neuralese ещё устанавливается. Попробуйте ещё раз через несколько секунд.`
- English: `Neuralese is still connecting. Please try again in a few seconds.`
- Kazakh: `Neuralese жүйесіне қосылу әлі аяқталған жоқ. Бірнеше секундтан кейін қайталап көріңіз.`

The action then stops. It does not open a login splash, create an Axon pending message, clear chat history, mutate classroom state, start a progress spinner, or enqueue work.

If authentication completes later, the next user click proceeds normally.

## Background Behavior

Background calls use a silent readiness predicate and return their neutral result without displaying UI:

- Axon history preload returns an empty/cached history;
- classroom metadata preload and SSE startup return without opening a connection;
- classroom event mirroring skips the event;
- hidden warm-up or cleanup work skips a remote-only operation;
- startup continues without waiting for any of these calls.

Background code must not call the interactive guard because repeated startup tasks would produce error-toast spam.

## Transport Enforcement

`WebAPI` classifies a route before creating a thread or `HTTPClient`. For a protected route it obtains the current bearer header from `CookieManager`. If the token is missing, it returns the existing asynchronous response shape with `ok = false` and `error_code = "auth_not_ready"`; no network thread is created.

`Sockets.connect_to()` applies the same rule before constructing `SocketConnection`. A protected connection without a bearer token returns `null` and does not add anything to `_conns`. All current callers handle this nullable result, while their interactive entry points are responsible for the visible error.

Protected transports attach the bearer header themselves. Feature code no longer calls `cookies.get_auth_header()`. The compatibility method is removed after migration because it can return local-profile data that is not an authorization header.

`Transcriber` keeps its raw audio transport but applies the same bearer check before constructing `HTTPRequest`; it returns a rejected asynchronous handle when unavailable and attaches the bearer header when allowed.

Authentication bootstrap keeps its dedicated transport path and is not recursively blocked by the protected-route guard.

## Call-Site Policy

### Axon

Interactive guards are required before opening Axon, sending text, beginning transcription, clearing a chat, and sending a node-info context request. `AIHelpMenu.send_message()` performs its guard before adding either the user bubble or pending assistant bubble.

Hidden Axon preload and `re_recv()` are background operations and silently stop when no remote session exists.

### Classrooms and Lessons

Joining, leaving, creating, uploading, locking/unlocking lessons, and explicit teacher/student controls are interactive. Metadata cache, SSE setup, automatic state mirroring, and lesson auto-project prefetch are background.

No classroom profile or lesson state is mutated before readiness is established. In particular, leaving cannot clear `my_classroom` and lesson upload cannot mutate `classroom_data` if the protected request cannot start.

### Projects, Datasets, Training, Inference, and Export

Local branches remain before the remote guard. Only the remote fallback is gated. This preserves offline/local behavior even while authentication is pending or permanently unavailable.

Remote project create/open/delete/save guards run before modifying `parsed_projects`, replacing the current graph, or showing progress. Remote training/inference/export guards run before setting node state, starting progress UI, or creating sockets.

## Static Boundary Audit

The boundary audit scans `scripts/**/*.gd`, ignoring comments, and fails when:

- `HTTPClient.new`, `HTTPRequest.new`, `WebSocketPeer.new`, or `TCPServer.new` appears outside an approved raw-transport file;
- `web._request` is called outside `web.gd` or the approved auth compatibility adapter;
- `cookies.get_auth_header()` appears anywhere;
- a literal `web.POST`, `web.JPOST`, `web.GET`, `web.GET_SSE`, `web.HEALTH`, or `sockets.connect_to` route is absent from the catalog;
- a dynamic route is used outside an explicitly approved absolute-URL call site;
- a protected WebSocket caller omits handling for a refused connection.

This creates a closed-world inventory: a developer adding a new route or bypass must classify it in the same change.

## Testing

Automated tests cover:

- local identity true while remote session false;
- three-language error copy;
- public, protected, external, and unknown route classification;
- protected REST rejection without starting a network thread;
- protected WebSocket rejection without creating a peer or storing a connection;
- automatic bearer attachment when a token exists;
- Axon denial before message/UI mutation;
- passive startup work producing no `ui.error`;
- classroom denial before local state mutation;
- local training/inference/project paths remaining usable without a token;
- endpoint-catalog and transport-boundary completeness.

Manual verification uses a throttled or disconnected network: onboarding appears immediately, early Axon/classroom clicks show one error, no partial UI remains, and a later click succeeds after authentication completes.

## Non-Goals

- Waiting for authentication before onboarding or tutorial UI.
- Queuing and replaying rejected user actions.
- Redesigning login, onboarding, Axon, classroom, or project screens.
- Changing backend authorization rules or token storage.
- Forcing local runtime features to require a remote session.

## Acceptance Criteria

The change is complete when onboarding never waits for authentication, every protected request is denied before network creation without a bearer token, interactive denials show exactly one localized error before UI mutation, background work skips silently, local runtime behavior is unchanged, and the static audit proves every network route and raw transport has an explicit policy.
