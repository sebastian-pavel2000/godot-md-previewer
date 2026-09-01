@tool
extends RefCounted
class_name MarkdownParser

## Converts Markdown text to BBCode for RichTextLabel rendering.
## Images are replaced with placeholder tags for async loading.
## Returns a Dictionary: { "bbcode": String, "images": Array[Dictionary] }
## Each image entry: { "id": int, "url": String, "type": "local"|"external" }

static func parse(md: String) -> Dictionary:
	var lines := md.split("\n")
	var output := ""
	var in_code_block := false
	var code_block_lang := ""
	var code_block_lines: Array[String] = []
	var in_ordered_list := false
	var in_unordered_list := false
	var images: Array[Dictionary] = []

	var i := 0
	while i < lines.size():
		var raw_line: String = lines[i]
		var line: String = raw_line.rstrip(" \t")

		# --- Table detection ---
		# A table starts with a row like "| a | b |" followed by a
		# separator row like "|---|---|" or "| :-- | --: |"
		if not in_code_block and _is_table_row(line) and i + 1 < lines.size() and _is_table_separator(lines[i + 1]):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false

			var table_lines: Array[String] = [line]
			var j := i + 2  # skip the separator row
			while j < lines.size() and _is_table_row(lines[j]):
				table_lines.append(lines[j])
				j += 1

			output += _render_table(table_lines, images)
			i = j
			continue

		# --- Code block open/close ---
		if line.begins_with("```"):
			if in_code_block:
				var code_text := "\n".join(code_block_lines)
				code_text = code_text.replace("[", "[lb]")
				output += "[font_size=12][color=#cdd6f4][bgcolor=#1a1f2e]%s[/bgcolor][/color][/font_size]\n" % code_text
				in_code_block = false
				code_block_lang = ""
				code_block_lines.clear()
			else:
				if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
				if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
				in_code_block = true
				code_block_lang = line.substr(3).strip_edges()
			i += 1
			continue

		if in_code_block:
			code_block_lines.append(raw_line)
			i += 1
			continue

		# --- Empty line ---
		if line.strip_edges() == "":
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "\n"
			i += 1
			continue

		# --- Horizontal rule ---
		var hr_check := line.strip_edges()
		if hr_check == "---" or hr_check == "***" or hr_check == "___" or hr_check == "- - -" or hr_check == "* * *":
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[color=#4a5568]─────────────────────────────────────────────────[/color]\n"
			i += 1
			continue

		# --- Headers ---
		if line.begins_with("#### "):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[font_size=15][color=#e8c87a][b]%s[/b][/color][/font_size]\n" % _inline(line.substr(5), images)
			i += 1
			continue
		if line.begins_with("### "):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[font_size=17][color=#7aa2f7][b]%s[/b][/color][/font_size]\n" % _inline(line.substr(4), images)
			i += 1
			continue
		if line.begins_with("## "):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[font_size=21][color=#89dceb][b]%s[/b][/color][/font_size]\n" % _inline(line.substr(3), images)
			i += 1
			continue
		if line.begins_with("# "):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[font_size=27][color=#f38ba8][b]%s[/b][/color][/font_size]\n" % _inline(line.substr(2), images)
			i += 1
			continue

		# --- Blockquote ---
		if line.begins_with("> "):
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			output += "[color=#4a5568]▎[/color] [color=#a6adc8][i]%s[/i][/color]\n" % _inline(line.substr(2), images)
			i += 1
			continue

		# --- Unordered list ---
		var ul_match := _ul_match(line)
		if ul_match != "":
			if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false
			if not in_unordered_list: output += "[ul bullet=•]\n"; in_unordered_list = true
			output += _inline(ul_match, images) + "\n"
			i += 1
			continue

		# --- Ordered list ---
		var ol_match := _ol_match(line)
		if ol_match != "":
			if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
			if not in_ordered_list: output += "[ol type=1]\n"; in_ordered_list = true
			output += _inline(ol_match, images) + "\n"
			i += 1
			continue

		# --- Close lists ---
		if in_unordered_list: output += "[/ul]\n"; in_unordered_list = false
		if in_ordered_list: output += "[/ol]\n"; in_ordered_list = false

		# --- Normal paragraph ---
		output += _inline(line, images) + "\n"
		i += 1

	if in_unordered_list: output += "[/ul]\n"
	if in_ordered_list: output += "[/ol]\n"
	if in_code_block:
		var code_text := "\n".join(code_block_lines).replace("[", "[lb]")
		output += "[font_size=12][color=#cdd6f4][bgcolor=#1a1f2e]%s[/bgcolor][/color][/font_size]\n" % code_text

	return { "bbcode": output, "images": images }


static func _inline(text: String, images: Array[Dictionary]) -> String:
	var result := text

	# Images MUST be extracted BEFORE escaping brackets
	var img_regex := RegEx.new()
	img_regex.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
	var img_results := img_regex.search_all(result)
	for i in range(img_results.size() - 1, -1, -1):
		var m := img_results[i]
		var url: String = m.get_string(2)
		var id := images.size()
		var img_type := "external" if (url.begins_with("http://") or url.begins_with("https://")) else "local"
		images.append({ "id": id, "url": url, "type": img_type })
		var placeholder := "IMG_PLACEHOLDER_%d" % id
		result = result.substr(0, m.get_start()) + placeholder + result.substr(m.get_end())

	# NOW escape brackets — placeholders use [[ ]] so they survive this
	result = result.replace("[", "[lb]")

	# Links also before bracket escape would be better, but links use []()
	# so they need to be extracted too — do it here after image extraction
	var link_regex := RegEx.new()
	link_regex.compile(r"\[([^\]]+)\]\(([^)]+)\)")
	var link_results := link_regex.search_all(result)
	for i in range(link_results.size() - 1, -1, -1):
		var m := link_results[i]
		var link_text: String = m.get_string(1)
		var replacement := "[color=#7aa2f7][u]%s[/u][/color]" % link_text
		result = result.substr(0, m.get_start()) + replacement + result.substr(m.get_end())

	# Inline code
	result = _replace_pattern(result, "`([^`]+)`",
		"[font_size=12][color=#a6e3a1][bgcolor=#1e2030] $1 [/bgcolor][/color][/font_size]")

	# Bold+italic
	result = _replace_pattern(result, r"\*\*\*(.+?)\*\*\*", "[b][i]$1[/i][/b]")
	result = _replace_pattern(result, r"___(.+?)___", "[b][i]$1[/i][/b]")

	# Bold
	result = _replace_pattern(result, r"\*\*(.+?)\*\*", "[b]$1[/b]")
	result = _replace_pattern(result, r"__(.+?)__", "[b]$1[/b]")

	# Italic
	result = _replace_pattern(result, r"\*(.+?)\*", "[i]$1[/i]")
	result = _replace_pattern(result, r"(?<!\w)_(.+?)_(?!\w)", "[i]$1[/i]")

	# Strikethrough
	result = _replace_pattern(result, r"~~(.+?)~~", "[s]$1[/s]")

	return result


static func _replace_pattern(text: String, pattern: String, replacement: String) -> String:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return text
	return regex.sub(text, replacement, true)


static func _ul_match(line: String) -> String:
	var regex := RegEx.new()
	regex.compile(r"^[\*\-\+] (.+)$")
	var result := regex.search(line)
	if result:
		return result.get_string(1)
	return ""


static func _ol_match(line: String) -> String:
	var regex := RegEx.new()
	regex.compile(r"^\d+\. (.+)$")
	var result := regex.search(line)
	if result:
		return result.get_string(1)
	return ""


# ── Tables ──────────────────────────────────────────────────────────────────

## A table row: a trimmed line that contains at least one "|"
static func _is_table_row(line: String) -> bool:
	var trimmed := line.strip_edges()
	if trimmed == "":
		return false
	return trimmed.contains("|")


## A separator row looks like: |---|---|  or  | :-- | :-: | --: |
static func _is_table_separator(line: String) -> bool:
	var trimmed := line.strip_edges()
	if trimmed == "" or not trimmed.contains("|"):
		return false
	var regex := RegEx.new()
	regex.compile(r"^\|?[\s:|-]+\|?$")
	if regex.search(trimmed) == null:
		return false
	# Must contain at least one dash to distinguish from an empty row
	return trimmed.contains("-")


## Splits a table row on unescaped "|" into cell strings, trimming
## the leading/trailing empty cells produced by a leading/trailing "|".
static func _split_table_row(line: String) -> Array[String]:
	var trimmed := line.strip_edges()
	if trimmed.begins_with("|"):
		trimmed = trimmed.substr(1)
	if trimmed.ends_with("|"):
		trimmed = trimmed.substr(0, trimmed.length() - 1)

	var cells := trimmed.split("|")
	var result: Array[String] = []
	for c in cells:
		result.append(c.strip_edges())
	return result


## Renders a list of table row strings (header + body, separator already
## excluded) as Godot BBCode using the [table=N] tag. Since RichTextLabel's
## [table] tag has no border support, rows are zebra-striped with alternating
## backgrounds for visual separation instead of literal grid lines.
static func _render_table(table_lines: Array[String], images: Array[Dictionary]) -> String:
	if table_lines.is_empty():
		return ""

	var header_cells := _split_table_row(table_lines[0])
	var col_count := header_cells.size()
	if col_count == 0:
		return ""

	var bbcode := "[table=%d]\n" % col_count

	# Header row — distinct background + bold + accent color
	for cell in header_cells:
		var content := _inline(cell, images)
		bbcode += "[cell][bgcolor=#3a4358][color=#89dceb][b] %s [/b][/color][/bgcolor][/cell]" % content
	bbcode += "\n"

	# Body rows — zebra striped so rows are visually separated
	for row_idx in range(1, table_lines.size()):
		var cells := _split_table_row(table_lines[row_idx])
		var row_bg := "#232838" if (row_idx % 2 == 1) else "#1a1f2e"
		for col in range(col_count):
			var cell_text := cells[col] if col < cells.size() else ""
			var content := _inline(cell_text, images)
			bbcode += "[cell][bgcolor=%s] %s [/bgcolor][/cell]" % [row_bg, content]
		bbcode += "\n"

	bbcode += "[/table]\n"
	return bbcode
