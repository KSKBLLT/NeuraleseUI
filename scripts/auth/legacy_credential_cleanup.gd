extends RefCounted
class_name LegacyCredentialCleanup

# This migration is intentionally isolated from the runtime auth path.
const _OBSOLETE_SECRET_KEYS := [
	"clerk_access_token",
	"clerk_refresh_token",
	"clerk_user",
]


static func remove_from(values: Dictionary) -> bool:
	var changed := false
	for key in _OBSOLETE_SECRET_KEYS:
		if values.erase(key):
			changed = true
	return changed
