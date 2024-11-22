@tool
extends EditorScenePostImportPlugin

var scene_path: String = ""

func _get_import_options(path: String):
	# Another hack!
	# We don't actually want to add import options,
	# this is just a way to trick Godot into giving us the scene path :)
	scene_path = path
