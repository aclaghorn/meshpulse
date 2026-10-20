extends SceneTree
## Renders splash.png (icon.svg above the MESH PULSE wordmark, in the app's own font and colours)
## for application/boot_splash/image. Needs a window to render, so not --headless:
##   godot --path . -s tools/make_splash.gd

const SIZE := Vector2i(720, 400)
const ICON_PX := 168
const OUT := "res://splash.png"


func _initialize() -> void:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.size = SIZE
	vp.add_child(bg)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 22)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.size = SIZE
	vp.add_child(box)

	# Rasterise the SVG at the target size rather than scaling the 128 px imported texture.
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	var img := Image.new()
	img.load_svg_from_string(svg, float(ICON_PX) / 128.0)
	var icon := TextureRect.new()
	icon.texture = ImageTexture.create_from_image(img)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(icon)

	var title := UiTheme.label("MESH PULSE", 54, UiTheme.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_save.call_deferred(vp)


func _save(vp: SubViewport) -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := vp.get_texture().get_image().save_png(OUT)
	print("saved %s (%s)" % [OUT, error_string(err)])
	quit(err)
