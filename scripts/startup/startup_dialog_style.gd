extends RefCounted
class_name StartupDialogStyle

const FORM_SIZE := {"width": 560, "height": 300}
const BASE_APPEARANCE := {
	"title_font_size": 32,
	"button_height": 50,
	"button_width": 500,
	"button_font_scale": 0.62,
	"field_height": 44,
	"field_font_size": 18,
	"field_font_scale": 0.56,
	"field_label_font_size": 16,
	"action_separation": 12,
}


static func appearance(overrides: Dictionary = {}) -> Dictionary:
	var result := BASE_APPEARANCE.duplicate(true)
	result.merge(overrides, true)
	return result
