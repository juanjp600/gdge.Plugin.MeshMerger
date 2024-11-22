@tool
extends EditorPlugin

const MeshMergerPostImportPlugin = preload("res://addons/mesh_merger/mesh_merger_post_import.gd")

var merge_button: Button = null
var import_viewport: SubViewport = null
var the_dialog: ConfirmationDialog = null
var post_import_plugin: MeshMergerPostImportPlugin = null

func _enter_tree() -> void:
	if !Engine.is_editor_hint():
		return

	post_import_plugin = MeshMergerPostImportPlugin.new()
	add_scene_post_import_plugin(post_import_plugin)
	
	# Major hack job to find two UI elements in the "Advanced Import Settings for Scene" dialog.
	# Godot doesn't offer a clean way of modifying this dialog but it exists in the scene tree
	# so by looking at the internals it's possible to add stuff to it
	var all_nodes = get_tree().get_root().find_children("*", "ConfirmationDialog", true, false)
	for node in all_nodes:
		if node.get_class() == "SceneImportSettingsDialog":
			the_dialog = node
			break
	var dialog_nodes = the_dialog.get_children()
	var root_vbox_children = dialog_nodes[0].get_children()
	
	var button_container = root_vbox_children[0]
	merge_button = Button.new()
	merge_button.text = "Export as single mesh resource"
	merge_button.pressed.connect(self._export_as_single_mesh_resource)
	button_container.add_child(merge_button)
	
	var inner_container_1 = root_vbox_children[1]
	var inner_container_2 = inner_container_1.get_child(1)
	var inner_container_3 = inner_container_2.get_child(0)
	var subviewport_container = inner_container_3.get_child(0)
	
	import_viewport = subviewport_container.get_child(0)

func _get_imported_scene() -> Node:
	# More hacks.
	# The scene that we want to work with is always the last child of the viewport we see it through.
	# This is incorrect when we haven't loaded a scene yet, but we don't call this function in that case.
	return import_viewport.get_child(import_viewport.get_child_count() - 1)

func _export_as_single_mesh_resource():
	the_dialog.hide()
	var save_dialog = FileDialog.new()
	save_dialog.access = FileDialog.ACCESS_RESOURCES
	save_dialog.mode = Window.MODE_WINDOWED
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.add_filter("*.tres", "Text Resource")
	save_dialog.file_selected.connect(_save_single_mesh_resource)
	save_dialog.size = Vector2i(800,600)
	save_dialog.current_file = _get_imported_scene().name + ".tres"
	save_dialog.current_dir = post_import_plugin.scene_path.get_base_dir()
	add_child(save_dialog)
	save_dialog.popup_centered()

func _save_single_mesh_resource(path: String):
	var merged_mesh = _generate_merged_mesh()
	ResourceSaver.save(merged_mesh, path)

func _get_transformed_arrays(mesh: ArrayMesh, surface_index: int, transform: Transform3D) -> Array:
	var arrays = mesh.surface_get_arrays(surface_index)

	var vertex_array: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normal_array: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangent_array: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]

	for i in range(0, vertex_array.size()):
		vertex_array[i] = transform * vertex_array[i]

	if normal_array != null:
		for i in range(0, normal_array.size()):
			normal_array[i] = (transform.basis * normal_array[i]).normalized()

	if tangent_array != null:
		for i in range(0, tangent_array.size() / 4):
			var tangent: Vector3 = Vector3(tangent_array[i * 4 + 0], tangent_array[i * 4 + 1], tangent_array[i * 4 + 2])
			tangent = (transform.basis * tangent).normalized()
			tangent_array[i * 4 + 0] = tangent.x
			tangent_array[i * 4 + 1] = tangent.y
			tangent_array[i * 4 + 2] = tangent.z
	
	return arrays

func _append_surface_arrays(existing_surface: Array, arrays: Array):
	arrays = arrays.duplicate(true)
	if existing_surface[Mesh.ARRAY_VERTEX] != null:
		for i in range(0, arrays[Mesh.ARRAY_INDEX].size()):
			arrays[Mesh.ARRAY_INDEX][i] = arrays[Mesh.ARRAY_INDEX][i] + existing_surface[Mesh.ARRAY_VERTEX].size()
	for i in range(0, Mesh.ARRAY_MAX):
		if arrays[i] != null:
			if existing_surface[i] != null:
				existing_surface[i].append_array(arrays[i])
			else:
				existing_surface[i] = arrays[i]

func _generate_merged_mesh() -> ArrayMesh:
	var imported_scene = _get_imported_scene()
	
	var mesh_instances = imported_scene.find_children("*", "MeshInstance3D", true, false)
	
	var retval = ArrayMesh.new()
	var shadow_retval = ArrayMesh.new()

	# The easy thing to do would be to just add all surfaces directly,
	# but given that it's likely that the imported scene reuses materials,
	# for convenience we track that and merge everything into as few surfaces
	# as possible
	var surfaces: Dictionary = {}
	var shadow_surfaces: Dictionary = {}

	for mesh_instance in mesh_instances:
		if !(mesh_instance is MeshInstance3D):
			continue
		var mesh: Mesh = mesh_instance.mesh
		if !(mesh is ArrayMesh):
			continue

		var transform: Transform3D = mesh_instance.global_transform
		for surface_index in range(0, mesh.get_surface_count()):
			var arrays: Array = _get_transformed_arrays(mesh, surface_index, transform)

			var material: BaseMaterial3D = mesh.surface_get_material(surface_index)
			if material == null:
				continue

			if !surfaces.has(material):
				surfaces[material] = []
				surfaces[material].resize(Mesh.ARRAY_MAX)
			_append_surface_arrays(surfaces[material], arrays)

			# Discard unnecessary data here
			arrays[Mesh.ARRAY_COLOR] = null
			arrays[Mesh.ARRAY_TEX_UV] = null
			arrays[Mesh.ARRAY_TEX_UV2] = null
			arrays[Mesh.ARRAY_NORMAL] = null
			arrays[Mesh.ARRAY_TANGENT] = null
			if !shadow_surfaces.has(material):
				shadow_surfaces[material] = []
				shadow_surfaces[material].resize(Mesh.ARRAY_MAX)
			_append_surface_arrays(shadow_surfaces[material], arrays)

	for material in surfaces:
		var arrays = surfaces[material]
		retval.add_surface_from_arrays(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES, arrays)
		retval.surface_set_material(retval.get_surface_count() - 1, material)

	for material in shadow_surfaces:
		var arrays = shadow_surfaces[material]
		shadow_retval.add_surface_from_arrays(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES, arrays)

	retval.shadow_mesh = shadow_retval

	return retval

func _process(delta: float) -> void:
	pass

func _exit_tree() -> void:
	if merge_button != null:
		merge_button.get_parent().remove_child(merge_button)
	if post_import_plugin != null:
		remove_scene_post_import_plugin(post_import_plugin)
	merge_button = null
	post_import_plugin = null

func _has_main_screen() -> bool:
	return false

func _make_visible(visible: bool) -> void:
	pass

func _get_plugin_name() -> String:
	return "Mesh Merger"

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")
