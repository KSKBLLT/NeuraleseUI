# Pilot onboarding integration

Pilot builds use one technical account per installation. The account is created
or restored automatically from the build enrollment and the stable local
installation ID. No browser, username, password, or device code is shown to a
student.

At every application launch, the startup UI asks only for the first and last
name of the person currently using the computer. This runtime identity is kept
separately from the technical account in local application storage and memory.
It can therefore change between lessons without changing the server account.

Use `PilotOnboardingClient` from
`res://scripts/auth/pilot_onboarding_client.gd`. The build/deployment owns the
enrollment ID and token; they must not be typed by a child.

```gdscript
var pilot = PilotOnboardingClient.new(web, cookies)
var installation_id = PilotOnboardingClient.get_or_create_installation_id()
var result = await pilot.ensure_device_session(
	account_role,
	enrollment_id,
	enrollment_token,
	installation_id
)
```

`account_role` comes from `NEURALESE_PILOT_ACCOUNT_ROLE` and defaults to
`student`. Teacher authorization still depends on the server-side enrollment
policy. It is never selected by the child.

On success, `cookies` immediately contains an authenticated in-memory pilot
session and the non-secret device profile. Access and refresh tokens are not
written to the cookie file. Existing authenticated requests and refresh logic
continue through the normal Neuralese API. The visible first and last name are
then applied with `cookies.set_pilot_runtime_identity(...)`; they are not sent
to the pilot registration endpoint.

Treat these backend errors as stable UI states:

- `pilot_enrollment_denied`: this build or enrollment is not authorized.
- `pilot_role_not_allowed`: the enrollment cannot create the selected role.
- `pilot_profile_conflict`: the locally cached legacy device profile no longer
  matches the server-side pilot account.

For compatibility, an installation registered by an older build reuses its
stored server-side name and role during silent authentication. The current
student name still remains a separate local runtime identity.
