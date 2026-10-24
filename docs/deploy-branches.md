# Deploy branches

Neuralese uses two explicit deployment lanes:

- `pilot-deploy` is the exact source used for school pilot builds.
- `prod-deploy` is the exact source used for non-pilot production builds.
- `main` remains the protected canonical history and pull-request base. It is not a deployment trigger.

The intended promotion path is:

```text
dev -> integration -> pilot-deploy -> prod-deploy
```

## Automatic checks and artifacts

Every push to `pilot-deploy` or `prod-deploy` starts three independent GitHub Actions workflows:

1. **Verify automatic updater** runs generated-node checks, JasonDocs/Python tests, Godot tests, and the HTTP updater integration test.
2. **Build Windows Branch Installer** runs release/integration/Godot tests, verifies the pinned installer source and runtime payload, and uploads `Neuralese-Setup.exe` with its SHA-256 and build metadata.
3. **Build macOS Branch DMG** runs release/integration/Godot tests, exports a universal `Neuralese.app`, verifies its signature, architectures, YAML/Lua libraries, and DMG integrity, then uploads the DMG with its SHA-256 and build metadata.

Artifacts include the deployment branch and commit SHA in their names, so pilot and production outputs cannot be confused.

## Safety boundary

Deploy-branch workflows have only `contents: read`. They cannot create GitHub Releases or replace the public stable installer. Windows candidate publication and production promotion remain separate manual workflows with the existing approval and QA gates.

The macOS artifact is ad-hoc signed and not notarized. It is suitable for internal pilot QA. Public macOS distribution still requires an Apple Developer ID certificate and notarization.

## GitHub branch protection

Protect `pilot-deploy` and `prod-deploy` in repository settings:

- require pull requests;
- require the updater, Windows, and macOS checks;
- block force pushes and branch deletion;
- require approval for `prod-deploy`;
- allow promotion to `prod-deploy` only from a tested `pilot-deploy` commit.
