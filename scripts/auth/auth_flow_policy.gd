extends RefCounted
class_name AuthFlowPolicy


static func resolve_display_identity(profile: Dictionary, user_info: Dictionary) -> String:
	for value in [
		profile.get("username"),
		user_info.get("username"),
		user_info.get("preferred_username"),
		profile.get("certificate_name"),
	]:
		var candidate := identity_text(value)
		if candidate != "":
			return candidate
	var full_name := " ".join(PackedStringArray([
		identity_text(profile.get("first_name")),
		identity_text(profile.get("last_name")),
	])).strip_edges()
	if full_name != "":
		return full_name
	for value in [
		profile.get("display_name"),
		user_info.get("display_name"),
		user_info.get("name"),
		user_info.get("email"),
	]:
		var candidate := identity_text(value)
		if candidate != "":
			return candidate
	return ""


static func login_result_with_profile_sync(
	login_result: Dictionary,
	profile_sync_result: Dictionary
) -> Dictionary:
	var combined := login_result.duplicate(true)
	if not profile_sync_result.get("ok", false):
		combined["profile_sync_error"] = profile_sync_result.duplicate(true)
	return combined


static func login_success_text(language: String) -> String:
	match language.strip_edges().to_lower():
		"ru":
			return "Вход выполнен"
		"kz":
			return "Кіру сәтті"
		_:
			return "Signed in"


## Password sessions are legacy; pilot and OIDC credentials are intentionally
## held by CookieManager's auth-session store.  Keeping this decision pure
## makes every login entry point use the same definition of "signed in".
static func is_signed_in(legacy_credentials: Dictionary, has_auth_session: bool) -> bool:
	return not legacy_credentials.is_empty() or has_auth_session


static func merge_pilot_runtime_identity(
	account_profile: Dictionary,
	runtime_identity: Dictionary
) -> Dictionary:
	var merged := account_profile.duplicate(true)
	for field in ["first_name", "last_name", "certificate_name"]:
		var value := identity_text(runtime_identity.get(field))
		if not value.is_empty():
			merged[field] = value
	return merged


static func identity_text(value: Variant) -> String:
	if value == null:
		return ""
	var text := str(value).strip_edges()
	return "" if text.to_lower() in ["null", "<null>"] else text
