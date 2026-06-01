@tool
extends Control
class_name Markdown_Preview_Panel

var panels:Array[String] =[];
## Markdown Previewer Panel
## Manages multiple MD file tabs, renders BBCode, and async-loads images.

const EMPTY_LABEL := "[color=#4a5568][i]No file open. Click  Open File  to load a .md file.[/i][/color]"
const IMAGE_TIMEOUT := 10.0
const MAX_IMAGE_WIDTH := 0  # 0 = full width

var tab_container: TabContainer
var toolbar: HBoxContainer
var open_btn: Button
var close_btn: Button
var reload_btn: Button
var file_label: Label
var file_dialog: FileDialog

# Maps tab index → { path, mtime, bbcode, images, pending_images }
var tab_data: Array[Dictionary] = []

# Active HTTP requests: request_node → { tab_idx, image_id, url, timer }
var active_requests: Dictionary = {}

var reload_timer: float = 0.0
var RELOAD_INTERVAL: float = 2.0


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	custom_minimum_size = Vector2(0, 200)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	toolbar = HBoxContainer.new()
	toolbar.custom_minimum_size.y = 32
	vbox.add_child(toolbar)

	open_btn = _make_button("📂 Open File", Color(0.42, 0.62, 0.87))
	open_btn.pressed.connect(_on_open_pressed)
	toolbar.add_child(open_btn)

	reload_btn = _make_button("🔄 Reload", Color(0.56, 0.82, 0.64))
	reload_btn.pressed.connect(_on_reload_pressed)
	reload_btn.disabled = true
	toolbar.add_child(reload_btn)

	close_btn = _make_button("✕ Close Tab", Color(0.95, 0.54, 0.54))
	close_btn.pressed.connect(_on_close_pressed)
	close_btn.disabled = true
	toolbar.add_child(close_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	file_label = Label.new()
	file_label.text = "No file open"
	file_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	file_label.add_theme_font_size_override("font_size", 11)
	file_label.clip_text = true
	file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(file_label)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	tab_container = TabContainer.new()
	tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_container.tab_changed.connect(_on_tab_changed)
	vbox.add_child(tab_container)

	_add_empty_tab()


func _make_button(label: String, color: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_color_override("font_color", color)
	btn.custom_minimum_size = Vector2(120, 26)
	return btn


func _make_preview_rtl() -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = false
	rtl.scroll_active = true
	rtl.scroll_following = false
	rtl.selection_enabled = true
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.add_theme_font_size_override("normal_font_size", 14)
	rtl.add_theme_color_override("default_color", Color(0.88, 0.88, 0.88))
	return rtl


func _add_empty_tab() -> void:
	if tab_container.tab_changed.is_connected(_on_tab_changed):
		tab_container.tab_changed.disconnect(_on_tab_changed)
	var rtl := _make_preview_rtl()
	tab_container.add_child(rtl)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Welcome")
	tab_data.append({ "path": "", "mtime": 0, "bbcode": "", "images": [], "pending_images": 0 })
	rtl.parse_bbcode(EMPTY_LABEL)
	if not tab_container.tab_changed.is_connected(_on_tab_changed):
		tab_container.tab_changed.connect(_on_tab_changed)


# ── File Loading ──────────────────────────────────────────────────────────────
func _load_files(paths: Array[String]) -> void:
	for i in paths:
		if (i.length() >= 1):
			_load_file(i);

func _load_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("MDPreviewer: File not found: " + path)
		return

	for i in tab_data.size():
		if tab_data[i].path == path:
			tab_container.current_tab = i
			return

	var fa := FileAccess.open(path, FileAccess.READ)
	var md_text := fa.get_as_text()
	fa.close()

	var result := MarkdownParser.parse(md_text)
	var bbcode: String = result["bbcode"]
	var images: Array = result["images"]

	var empty_idx := -1
	for i in tab_data.size():
		if (tab_data[i].path as String) == "":
			empty_idx = i
			break

	var target_idx: int
	if empty_idx >= 0:
		target_idx = empty_idx
		tab_data[target_idx] = { "path": path, "mtime": _get_mtime(path), "bbcode": bbcode, "images": images, "pending_images": 0 }
		tab_container.set_tab_title(target_idx, path.get_file())
		tab_container.current_tab = target_idx
	else:
		if tab_container.tab_changed.is_connected(_on_tab_changed):
			tab_container.tab_changed.disconnect(_on_tab_changed)
		var rtl := _make_preview_rtl()
		tab_container.add_child(rtl)
		target_idx = tab_container.get_tab_count() - 1
		tab_container.set_tab_title(target_idx, path.get_file())
		tab_data.append({ "path": path, "mtime": _get_mtime(path), "bbcode": bbcode, "images": images, "pending_images": 0 })
		if not tab_container.tab_changed.is_connected(_on_tab_changed):
			tab_container.tab_changed.connect(_on_tab_changed)
		tab_container.current_tab = target_idx

	_render_tab(target_idx)
	_refresh_toolbar()
	panels.append(path);


func _render_tab(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_data.size():
		return

	var images: Array = tab_data[tab_idx]["images"]

	# Reset all image states for fresh render
	for img in images:
		img.erase("texture")
		img.erase("loaded")
		img.erase("failed")

	tab_data[tab_idx]["pending_images"] = images.size()

	# Initial render — shows loading placeholders for images
	_rebuild_tab_bbcode(tab_idx)

	# Start async loading
	var path: String = tab_data[tab_idx]["path"]
	var md_dir := path.get_base_dir()
	if md_dir.begins_with("res://"):
		md_dir = ProjectSettings.globalize_path(md_dir)

	for img in images:
		_load_image(tab_idx, img["id"], img["url"], img["type"], md_dir)


func _load_image(tab_idx: int, image_id: int, url: String, img_type: String, base_dir: String) -> void:
	if img_type == "local":
		_load_local_image(tab_idx, image_id, url, base_dir)
	else:
		_load_external_image(tab_idx, image_id, url)


func _load_local_image(tab_idx: int, image_id: int, url: String, base_dir: String) -> void:
	var full_path := url
	if not url.is_absolute_path() and not url.begins_with("res://") and not url.begins_with("user://"):
		full_path = base_dir.path_join(url)

	if full_path.begins_with("res://"):
		full_path = ProjectSettings.globalize_path(full_path)

	if not FileAccess.file_exists(full_path):
		_on_image_failed(tab_idx, image_id, url)
		return

	# Read raw bytes and detect format manually
	var fa := FileAccess.open(full_path, FileAccess.READ)
	if fa == null:
		_on_image_failed(tab_idx, image_id, url)
		return
	var bytes := fa.get_buffer(fa.get_length())
	fa.close()

	var img := Image.new()
	var err := ERR_INVALID_DATA

	# Detect by magic bytes instead of extension
	if bytes.size() >= 6 and bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46:
		_on_image_failed_with_message(tab_idx, image_id, "GIF format not supported (Godot 4 limitation)")
		return
	elif bytes.size() >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50:
		# PNG
		err = img.load_png_from_buffer(bytes)
	elif bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		# JPG
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 4 and bytes[0] == 0x52 and bytes[1] == 0x49:
		# WebP
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
		if err != OK:
			img = Image.new()
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			img = Image.new()
			err = img.load_gif_from_buffer(bytes)
		if err != OK:
			img = Image.new()
			err = img.load_webp_from_buffer(bytes)

	if err != OK or img.is_empty():
		_on_image_failed(tab_idx, image_id, url)
		return

	_on_image_loaded(tab_idx, image_id, img)


func _load_external_image(tab_idx: int, image_id: int, url: String) -> void:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.max_redirects = 5  # follow redirects
	add_child(http)

	var request_key := "%d_%d" % [tab_idx, image_id]
	active_requests[request_key] = {
		"node": http,
		"tab_idx": tab_idx,
		"image_id": image_id,
		"url": url,
		"elapsed": 0.0,
		"retries": 0
}

	http.request_completed.connect(
		func(result, response_code, headers, body):
			_on_http_completed(request_key, result, response_code, headers, body)
	)

	http.request(url)


func _on_http_completed(request_key: String, result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if not active_requests.has(request_key):
		return

	var req_data: Dictionary = active_requests[request_key]
	var tab_idx: int = req_data["tab_idx"]
	var image_id: int = req_data["image_id"]
	var url: String = req_data["url"]
	var http_node: HTTPRequest = req_data["node"]

	active_requests.erase(request_key)
	http_node.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var retries: int = req_data.get("retries", 0)
		if retries < 3 and result != HTTPRequest.RESULT_SUCCESS:
			# Retry after a short delay
			active_requests.erase(request_key)
			http_node.queue_free()
			await get_tree().create_timer(1.0).timeout
			var req_data_copy := {
				"tab_idx": tab_idx,
				"image_id": image_id,
				"url": url,
				"retries": retries + 1
			}
			_load_external_image_with_retry(tab_idx, image_id, url, retries + 1)
			return
		_on_image_failed(tab_idx, image_id, url)
		return

	# Detect format from Content-Type header first
	var content_type := ""
	for h in headers:
		if h.to_lower().begins_with("content-type:"):
			content_type = h.to_lower()
			break

	var img := Image.new()
	var load_err := ERR_INVALID_DATA

	if "jpeg" in content_type or "jpg" in content_type:
		load_err = img.load_jpg_from_buffer(body)
	elif "webp" in content_type:
		load_err = img.load_webp_from_buffer(body)
	elif "bmp" in content_type:
		load_err = img.load_bmp_from_buffer(body)
	else:
		# Detect by magic bytes
		if body.size() >= 6 and body[0] == 0x47 and body[1] == 0x49 and body[2] == 0x46:
			_on_image_failed(tab_idx, image_id, url)
			return
		elif body.size() >= 2 and body[0] == 0xFF and body[1] == 0xD8:
			load_err = img.load_jpg_from_buffer(body)
		elif body.size() >= 4 and body[0] == 0x89 and body[1] == 0x50:
			load_err = img.load_png_from_buffer(body)
		elif body.size() >= 4 and body[0] == 0x52 and body[1] == 0x49:
			load_err = img.load_webp_from_buffer(body)
		else:
			# Last resort — try everything
			for loader in [
				func(b): return img.load_png_from_buffer(b),
				func(b): img = Image.new(); return img.load_jpg_from_buffer(b),
				func(b): img = Image.new(); return img.load_webp_from_buffer(b),
				func(b): img = Image.new(); return img.load_gif_from_buffer(b),
			]:
				load_err = loader.call(body)
				if load_err == OK:
					break

	if load_err != OK or img.is_empty():
		_on_image_failed(tab_idx, image_id, url)
		return

	_on_image_loaded(tab_idx, image_id, img)

func _load_external_image_with_retry(tab_idx: int, image_id: int, url: String, retry_count: int) -> void:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.max_redirects = 5
	add_child(http)

	var request_key := "%d_%d_%d" % [tab_idx, image_id, retry_count]
	active_requests[request_key] = {
		"node": http,
		"tab_idx": tab_idx,
		"image_id": image_id,
		"url": url,
		"elapsed": 0.0,
		"retries": retry_count
	}

	http.request_completed.connect(
		func(result, response_code, headers, body):
			_on_http_completed(request_key, result, response_code, headers, body)
	)

	http.request(url)

func _on_image_loaded(tab_idx: int, image_id: int, img: Image) -> void:
	if tab_idx >= tab_data.size():
		return

	var texture := ImageTexture.create_from_image(img)

	# Store texture in tab_data so _rebuild_tab_bbcode can find it
	var images: Array = tab_data[tab_idx]["images"]
	for image_entry in images:
		if image_entry["id"] == image_id:
			image_entry["texture"] = texture
			image_entry["loaded"] = true
			break

	tab_data[tab_idx]["pending_images"] = max(0, (tab_data[tab_idx]["pending_images"] as int) - 1)

	_rebuild_tab_bbcode(tab_idx)


func _on_image_failed(tab_idx: int, image_id: int, url: String) -> void:
	if tab_idx >= tab_data.size():
		return

	_replace_placeholder_with_error(tab_idx, image_id, url)
	tab_data[tab_idx]["pending_images"] = max(0, (tab_data[tab_idx]["pending_images"] as int) - 1)


func _replace_placeholder(tab_idx: int, image_id: int, texture: ImageTexture) -> void:
	if tab_idx >= tab_data.size():
		return

	var rtl := tab_container.get_child(tab_idx) as RichTextLabel
	if rtl == null:
		return

	# Add texture to RTL and rebuild bbcode with [img] tag
	var tex_name := "img_%d" % image_id
	rtl.add_image(texture)

	# Rebuild the full bbcode with this image resolved
	_rebuild_tab_bbcode(tab_idx)


func _replace_placeholder_with_error(tab_idx: int, image_id: int, url: String) -> void:
	if tab_idx >= tab_data.size():
		return
	# Mark this image as failed so rebuild shows error
	var images: Array = tab_data[tab_idx]["images"]
	for img in images:
		if img["id"] == image_id:
			img["failed"] = true
			img["loaded"] = false
			break
	_rebuild_tab_bbcode(tab_idx)


func _rebuild_tab_bbcode(tab_idx: int) -> void:
	if tab_idx >= tab_data.size():
		return

	var rtl := tab_container.get_child(tab_idx) as RichTextLabel
	if rtl == null:
		return

	var data := tab_data[tab_idx]
	var bbcode: String = data["bbcode"]
	var images: Array = data["images"]

	var segments := _split_on_placeholders(bbcode, images)

	rtl.clear()

	for seg in segments:
		if seg["type"] == "text":
			rtl.append_text(seg["content"])
		elif seg["type"] == "image":
			var img_data: Dictionary = seg["image"]
			if img_data.get("loaded", false) and img_data.get("texture") != null:
				var tex: ImageTexture = img_data["texture"]
				var tex_w := tex.get_width()
				var tex_h := tex.get_height()
				var max_w := int(rtl.size.x) - 32
				if max_w <= 0:
					max_w = 600
				if tex_w > max_w:
					var scale := float(max_w) / float(tex_w)
					tex_h = int(tex_h * scale)
					tex_w = max_w
				rtl.add_image(tex, tex_w, tex_h)
			elif img_data.get("failed", false):
				rtl.append_text("[color=#f38ba8]❌ Failed to load: %s[/color]" % img_data["url"])
			else:
				rtl.append_text("[color=#a6adc8][i]⏳ Loading image...[/i][/color]")


func _split_on_placeholders(bbcode: String, images: Array) -> Array:
	var segments: Array = []
	var remaining := bbcode

	while remaining.length() > 0:
		var earliest_pos := remaining.length()
		var earliest_img: Dictionary = {}

		for img in images:
			var placeholder := "IMG_PLACEHOLDER_%d" % img["id"]
			var pos := remaining.find(placeholder)
			if pos >= 0 and pos < earliest_pos:
				earliest_pos = pos
				earliest_img = img

		if earliest_img.is_empty():
			segments.append({ "type": "text", "content": remaining })
			break
		else:
			if earliest_pos > 0:
				segments.append({ "type": "text", "content": remaining.substr(0, earliest_pos) })
			segments.append({ "type": "image", "image": earliest_img })
			var placeholder := "IMG_PLACEHOLDER_%d" % earliest_img["id"]
			remaining = remaining.substr(earliest_pos + placeholder.length())

	return segments


# ── Reload ────────────────────────────────────────────────────────────────────

func _reload_current() -> void:
	var idx := tab_container.current_tab
	if idx < 0 or idx >= tab_data.size():
		return
	var path: String = tab_data[idx].path
	if path == "" or not FileAccess.file_exists(path):
		return

	var fa := FileAccess.open(path, FileAccess.READ)
	var md_text := fa.get_as_text()
	fa.close()

	var result := MarkdownParser.parse(md_text)
	tab_data[idx]["bbcode"] = result["bbcode"]
	tab_data[idx]["images"] = result["images"]
	tab_data[idx]["mtime"] = _get_mtime(path)
	tab_data[idx]["pending_images"] = 0

	_render_tab(idx)


func _get_mtime(path: String) -> int:
	return FileAccess.get_modified_time(path)


func _refresh_toolbar() -> void:
	if tab_container == null or tab_data == null:
		return
	var idx := tab_container.current_tab
	if idx < 0 or idx >= tab_data.size():
		reload_btn.disabled = true
		close_btn.disabled = true
		file_label.text = "No file open"
		return
	var has_file: bool = (tab_data[idx].path as String) != ""
	reload_btn.disabled = not has_file
	close_btn.disabled = false
	file_label.text = tab_data[idx].path as String if has_file else "No file open"


# ── Signal Handlers ───────────────────────────────────────────────────────────

func _on_open_pressed() -> void:
	if file_dialog == null:
		file_dialog = FileDialog.new()
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.filters = ["*.md ; Markdown Files", "*.markdown ; Markdown Files"]
		file_dialog.file_selected.connect(_on_file_selected)
		add_child(file_dialog)
	file_dialog.popup_centered(Vector2(800, 600))


func _on_file_selected(path: String) -> void:
	_load_file(path)


func _on_reload_pressed() -> void:
	_reload_current()


func _on_close_pressed() -> void:
	_close_tab(tab_container.current_tab)


func _on_tab_changed(_tab: int) -> void:
	if tab_data == null or tab_data.size() == 0:
		return
	_refresh_toolbar()


func _close_tab(idx: int) -> void:
	if idx < 0 or idx >= tab_container.get_tab_count():
		return
	if tab_container.tab_changed.is_connected(_on_tab_changed):
		tab_container.tab_changed.disconnect(_on_tab_changed)
	var child := tab_container.get_child(idx)
	tab_container.remove_child(child)
	child.queue_free()
	panels.erase(tab_data[idx].get("path"));
	tab_data.remove_at(idx)
	if not tab_container.tab_changed.is_connected(_on_tab_changed):
		tab_container.tab_changed.connect(_on_tab_changed)
	if tab_container.get_tab_count() == 0:
		_add_empty_tab()
	_refresh_toolbar()


# ── Auto-reload ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return

	# Timeout check for external requests
	for key in active_requests.keys():
		var req: Dictionary = active_requests[key]
		req["elapsed"] = (req["elapsed"] as float) + delta
		if (req["elapsed"] as float) >= IMAGE_TIMEOUT:
			var http_node: HTTPRequest = req["node"]
			http_node.cancel_request()
			http_node.queue_free()
			_on_image_failed(req["tab_idx"], req["image_id"], req["url"])
			active_requests.erase(key)

	# File change detection
	reload_timer += delta
	if reload_timer < RELOAD_INTERVAL:
		return
	reload_timer = 0.0

	for i in tab_data.size():
		var path: String = tab_data[i].path
		if path == "" or not FileAccess.file_exists(path):
			continue
		var mtime := _get_mtime(path)
		if mtime != tab_data[i].mtime:
			var fa := FileAccess.open(path, FileAccess.READ)
			var md_text := fa.get_as_text()
			fa.close()
			var result := MarkdownParser.parse(md_text)
			tab_data[i]["bbcode"] = result["bbcode"]
			tab_data[i]["images"] = result["images"]
			tab_data[i]["mtime"] = mtime
			tab_data[i]["pending_images"] = 0
			_render_tab(i)

func _on_image_loaded_texture(tab_idx: int, image_id: int, tex: Texture2D) -> void:
	if tab_idx >= tab_data.size():
		return
	var images: Array = tab_data[tab_idx]["images"]
	for image_entry in images:
		if image_entry["id"] == image_id:
			image_entry["texture"] = tex
			image_entry["loaded"] = true
			break
	tab_data[tab_idx]["pending_images"] = max(0, (tab_data[tab_idx]["pending_images"] as int) - 1)
	_rebuild_tab_bbcode(tab_idx)


func _on_image_failed_with_message(tab_idx: int, image_id: int, message: String) -> void:
	if tab_idx >= tab_data.size():
		return
	var images: Array = tab_data[tab_idx]["images"]
	for img in images:
		if img["id"] == image_id:
			img["failed"] = true
			img["fail_message"] = message
			break
	tab_data[tab_idx]["pending_images"] = max(0, (tab_data[tab_idx]["pending_images"] as int) - 1)
	_rebuild_tab_bbcode(tab_idx)
