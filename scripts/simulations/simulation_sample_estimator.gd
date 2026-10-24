class_name SimulationSampleEstimator
extends RefCounted

const RandomizationProfile = preload(
	"res://scripts/simulations/simulation_randomization_profile.gd"
)

# The estimator intentionally uses broad coverage units instead of model
# internals. Dataset generation teaches the selected agent contract, so the
# relevant complexity is the number of observed/action channels, the amount of
# world geometry they must cover, and the enabled environment variations.
const MIN_SAMPLES := 1024
const MAX_SAMPLES := 32768
const SAMPLE_BLOCK := 256
const SAMPLES_PER_CHANNEL := 96
const SAMPLES_PER_WORLD_SCALE := 64
const VARIATION_COVERAGE := 0.18


static func recommend(world_state: Dictionary, binding: Dictionary) -> Dictionary:
	var input_width := maxi(0, int(binding.get("input_width", 0)))
	var output_width := maxi(0, int(binding.get("output_width", 0)))
	var channel_count := maxi(1, input_width + output_width)
	var objects: Variant = world_state.get("objects", [])
	var object_count := 1
	if objects is Array or objects is Dictionary:
		object_count = maxi(1, objects.size())
	var metadata: Dictionary = world_state.get("metadata", {})
	var active_variations := RandomizationProfile.active_config(
		metadata.get("randomization", {})
	)
	var variation_dimensions := _variation_dimensions(active_variations)

	var channel_coverage := channel_count * SAMPLES_PER_CHANNEL
	var world_coverage := ceili(sqrt(float(object_count))) * SAMPLES_PER_WORLD_SCALE
	var variation_multiplier := 1.0 + float(variation_dimensions) * VARIATION_COVERAGE
	var raw_count := ceili(float(channel_coverage + world_coverage) * variation_multiplier)
	var recommended := _round_up(raw_count, SAMPLE_BLOCK)
	recommended = clampi(recommended, MIN_SAMPLES, MAX_SAMPLES)

	return {
		"sample_count": recommended,
		"input_width": input_width,
		"output_width": output_width,
		"object_count": object_count,
		"variation_dimensions": variation_dimensions,
	}


static func sample_count(world_state: Dictionary, binding: Dictionary) -> int:
	return int(recommend(world_state, binding)["sample_count"])


static func _variation_dimensions(active_variations: Dictionary) -> int:
	var dimensions := 0
	for config_value in active_variations.values():
		if config_value is not Dictionary:
			dimensions += 1
			continue
		var config: Dictionary = config_value
		var has_vector_range := config.has("jitter") or config.has("range")
		dimensions += 2 if has_vector_range else 1
	return dimensions


static func _round_up(value: int, block_size: int) -> int:
	var safe_block := maxi(1, block_size)
	return ceili(float(value) / float(safe_block)) * safe_block
