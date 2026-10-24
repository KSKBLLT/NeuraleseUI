# Desktop authentication

Neuralese desktop uses a provider-neutral OpenID Connect client. The application
does not contain an identity-provider SDK, client secret, issuer, audience, or
client ID.

## Runtime contract

The only desktop bootstrap setting is:

```ini
[auth]
config_endpoint="/api/auth/config?client=desktop_pkce"
```

At runtime the client resolves this path against the active Neuralese API root.
The backend's `AuthProviderRegistry` returns the public OIDC contract:

- issuer and discovery URL;
- API audience;
- public desktop client ID;
- scopes;
- authorization flow and fixed loopback callback settings.

The response is schema-validated before any authorization endpoint is used.
Unknown fields, unsafe non-loopback HTTP URLs, mismatched discovery URLs, and
mismatched discovery issuers are rejected.

## Sign-in flow

The current desktop flow is OAuth 2.0 Authorization Code with PKCE:

1. Fetch the public desktop contract from the Neuralese backend.
2. Fetch OIDC discovery from the configured issuer.
3. Start an HTTP callback listener bound only to the configured
   `127.0.0.1` port.
4. Generate a cryptographically random PKCE verifier, challenge, and OAuth
   state value.
5. Open the normal Logto sign-in page in the system browser. The user signs in
   there with an enabled method such as email/password or Google; no device code
   is copied manually.
6. Accept the one-time authorization callback, require the exact callback path
   and state value, then exchange the code with the PKCE verifier.
7. Send only `Authorization: Bearer <access token>` to protected APIs.
8. Rotate the refresh token whenever the provider returns a new one.

No application secret is used because the desktop application is a public
client.

## Token storage

Access and refresh tokens are currently memory-only. They are never written to
`user://cookies.json`, project resources, logs, or exported bundles. Profile
metadata may still be persisted for UI compatibility.

This means a full application restart requires a new browser confirmation.
Persistent login must not be enabled until a reviewed macOS Keychain and Windows
Credential Manager adapter is available. Do not replace this with plaintext,
home-grown encryption, or a machine-derived key.

The one-time legacy cleanup module removes obsolete provider tokens from old
cookie files during startup.

## Configuration required in Logto

Create a Native application for the current desktop client and register the
exact loopback redirect URI published by the backend. Put its application ID
under `clients.desktop_pkce.client_id`. Create the API resource whose indicator
exactly matches the configured `audience`. Enable the scopes listed in the same
auth contract, including `openid` and `offline_access`.

The legacy `clients.desktop` entry remains a separate Device Flow application
for already installed builds. Do not reuse one Logto application for both
flows: Logto treats a device-flow Native application and an authorization-code
Native application as separate client configurations.

No Logto value is copied into Godot.

## Verification

Run the full Godot suite:

```bash
GODOT_BIN="/path/to/Godot" bash tests/godot/run_all.sh
```

With the backend and Logto running, verify the live bootstrap and discovery:

```bash
NEURALESE_AUTH_TEST_API=https://neuralese.asia \
  "$GODOT_BIN" --headless --path . --quit-after 60 \
  --script tests/godot/test_auth_live.gd
```

Manual release checks are still required on macOS and Windows for browser open,
callback completion, token refresh, logout, and protected project/Axon requests.
