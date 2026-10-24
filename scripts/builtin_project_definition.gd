class_name BuiltinProjectDefinition
extends Resource

@export_group("Identity")
@export var id: StringName
@export_file("*.scn") var source_scene: String
@export var version: int = 1
@export var sort_order: int = 0

@export_group("Presentation")
@export var preview: Texture2D
@export var emoji: String = "✨"
@export var accent_color: Color = Color(0.49, 0.83, 0.61, 1.0)

@export_group("Russian")
@export var title_ru: String
@export_multiline var description_ru: String
@export var tags_ru: PackedStringArray

@export_group("English")
@export var title_en: String
@export_multiline var description_en: String
@export var tags_en: PackedStringArray

@export_group("Kazakh")
@export var title_kz: String
@export_multiline var description_kz: String
@export var tags_kz: PackedStringArray


func localized_title(language: String) -> String:
	match language:
		"en": return title_en
		"kz": return title_kz
		_: return title_ru


func localized_description(language: String) -> String:
	match language:
		"en": return description_en
		"kz": return description_kz
		_: return description_ru


func localized_tags(language: String) -> PackedStringArray:
	match language:
		"en": return tags_en
		"kz": return tags_kz
		_: return tags_ru
