extends Control

func _ready() -> void:
	print("Test Debug Scene Running...")
	#
	## 1. The Dynamic Menu (Our primary test subject)
	#var dynamic_menu_def = {
		#"id": "dynamic_menu",
		#"type": "context",
		#"text": "Dynamic Test Menu",
		#"size": [200, 50],
		#"max_size": 250,
		#"color": Color(0.2, 0.2, 0.2, 0.8),
		#"static": true,
		#"children": [
			#{
				#"id": "btn_add",
				#"type": "block",
				#"text": "Add Dynamic Button",
				#"size": [180, 40],
				#"color": Color(0.4, 0.8, 0.4, 1.0)
			#},
			#{
				#"id": "btn_remove",
				#"type": "block",
				#"text": "Remove Dynamic Button",
				#"size": [180, 40],
				#"color": Color(0.8, 0.4, 0.4, 1.0)
			#}
		#]
	#}
	#
	#var dynamic_menu = UIAdapter.build(dynamic_menu_def)
	#UIAdapter.mount(self, dynamic_menu)
	#dynamic_menu.position = Vector2(50, 50)
	#
	#var dyn_state = {"count": 0}
	#var btn_add = dynamic_menu.button_by_hint.get(&"btn_add")
	#if btn_add:
		#btn_add.pressed.connect(func():
			#dyn_state.count += 1
			#var new_child = {
				#"id": "dyn_btn_" + str(dyn_state.count),
				#"type": "block",
				#"text": "Dynamic " + str(dyn_state.count),
				#"size": [180, 40],
				#"color": Color(0.5, 0.5, 0.8, 1.0)
			#}
			#UIAdapter.add_dynamic_child(dynamic_menu, new_child)
		#)
		#
	#var btn_remove = dynamic_menu.button_by_hint.get(&"btn_remove")
	#if btn_remove:
		#btn_remove.pressed.connect(func():
			#if dyn_state.count > 0:
				#UIAdapter.remove_dynamic_child(dynamic_menu, StringName("dyn_btn_" + str(dyn_state.count)))
				#dyn_state.count -= 1
		#)
#
	## 2. A Dropout Menu (Floating toolbar style)
	#var dropout_def = {
		#"id": "dropout_menu",
		#"type": "dropout",
		#"text": "Dropout Settings",
		#"size": [150, 40],
		#"color": Color(0.3, 0.3, 0.5, 0.9),
		#"static": false, # Dropout usually drops out when clicked!
		#"mouse_open": true, # Open on hover
		#"children": [
			#{ "id": "drop_1", "type": "block", "text": "Toggle Grid", "size": [130, 35], "color": Color(0.2, 0.2, 0.2) },
			#{ "id": "drop_2", "type": "block", "text": "Snap to Grid", "size": [130, 35], "color": Color(0.2, 0.2, 0.2) },
			#{ "id": "drop_3", "type": "block", "text": "Show Metrics", "size": [130, 35], "color": Color(0.2, 0.2, 0.2) }
		#]
	#}
	#
	#var dropout_menu = UIAdapter.build(dropout_def)
	#UIAdapter.mount(self, dropout_menu)
	#dropout_menu.position = Vector2(300, 50)
#
#
	## 3. Styled Blocks Menu (Demonstrating alignment, colors, offsets)
	#var styled_def = {
		#"id": "styled_menu",
		#"type": "context",
		#"text": "Styled Components",
		#"size": [220, 50],
		#"color": Color(0.15, 0.15, 0.15, 1.0),
		#"static": true,
		#"children": [
			#{
				#"id": "style_1",
				#"type": "block",
				#"text": "Left Aligned Text",
				#"size": [200, 40],
				#"color": Color(0.7, 0.3, 0.7, 1.0),
				#"text_alignment": [-1, 0], # Left align
				#"text_offset": [10, 0] # Padding from left
			#},
			#{
				#"id": "style_2",
				#"type": "block",
				#"text": "Right Aligned Text",
				#"size": [200, 40],
				#"color": Color(0.3, 0.7, 0.7, 1.0),
				#"text_alignment": [1, 0], # Right align
				#"text_offset": [-10, 0] # Padding from right
			#},
			#{
				#"id": "style_3",
				#"type": "block",
				#"text": "Centered Very Long Text That Marquees Automatically",
				#"size": [200, 40],
				#"color": Color(0.7, 0.7, 0.3, 1.0),
				#"text_alignment": [0, 0], # Center
				#"marquee": true,
				#"auto_trim": true
			#}
		#]
	#}
#
	#var styled_menu = UIAdapter.build(styled_def)
	#UIAdapter.mount(self, styled_menu)
	#styled_menu.position = Vector2(500, 50)
#
#
	## 4. Standalone Block Button
	#var standalone_def = {
		#"id": "standalone_btn",
		#"type": "block",
		#"text": "Isolated Block Button",
		#"size": [180, 50],
		#"color": Color(0.1, 0.5, 0.1, 1.0),
		#"static": true
	#}
#
	#var standalone_btn = UIAdapter.build(standalone_def)
	#UIAdapter.mount(self, standalone_btn)
	#standalone_btn.position = Vector2(750, 50)
#
	## 5. Test Onboarding Dialog
	#var dialog_test_def = {
		#"id": "btn_test_dialog",
		#"type": "block",
		#"text": "Test Onboarding Dialog",
		#"size": [220, 50],
		#"color": Color(0.8, 0.2, 0.8, 1.0),
		#"static": true
	#}
	#var btn_test_dialog = UIAdapter.build(dialog_test_def)
	#UIAdapter.mount(self, btn_test_dialog)
	#btn_test_dialog.position = Vector2(50, 150)
	if 0:
		glob.wait(1).connect(func():
			var ui = get_node_or_null("/root/ui")
			if ui and ui.has_method("show_dialog_and_get_result"):
				var spec = {
					"id": "test_onboarding",
					"title": "Welcome to Antigravity!",
					"body": "Please fill out this short onboarding form to help us understand your needs.",
					"format": "plain",
					"scale": 1,
					"transparent_background": false,
					"dismiss_on_escape": true,
					"dismiss_on_outside_click": true,
					"fields": [
						{
							"id": "username",
							"type": "text",
							"placeholder": "Enter your name...",
							"required": true
						},
						{
							"id": "network_pref",
							"type": "dropdown",
							"options": ["Convolutional (CNN)", "Recurrent (RNN)", "Transformer", "GAN"]
						}
					],
					"buttons": [
						{
							"id": "submit",
							"text": "Submit",
							"style": "primary"
						},
						{
							"id": "cancel",
							"text": "Cancel",
							"style": "secondary"
						}
					]
				}
				var result = await ui.show_dialog_and_get_result(spec)
				print("Dialog Result: ", result)
		)
