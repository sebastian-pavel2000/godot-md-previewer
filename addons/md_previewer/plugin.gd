@tool
extends EditorPlugin


var saveLocation = "res://addons/md_previewer/.local/md_panels.txt";
var activeTabLocation = "res://addons/md_previewer/.local/md_active_tab.txt";
var localFolder = "res://addons/md_previewer/.local"
var panel: Markdown_Preview_Panel

func _enter_tree() -> void:
	panel = preload("res://addons/md_previewer/md_previewer_panel.tscn").instantiate() as Markdown_Preview_Panel;
	add_control_to_bottom_panel(panel, "MD Preview")
	load_data(panel);

func _exit_tree() -> void:
	if panel:
		save_data(panel);
		remove_control_from_bottom_panel(panel)
		panel.queue_free()

func save_data(panel:Markdown_Preview_Panel) -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(localFolder)):
		DirAccess.make_dir_absolute(ProjectSettings.globalize_path(localFolder));
	var data = panel.panels;
	var activeTab = panel.tab_container.current_tab;
	var fa = FileAccess.open(saveLocation, FileAccess.WRITE);
	for file in data:
		fa.store_line(file);
	fa.close();
	
	fa = FileAccess.open(activeTabLocation, FileAccess.WRITE);
	fa.store_8(activeTab);
	fa.close();
	
	pass;
	
func load_data(panel:Markdown_Preview_Panel) -> void:	
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(localFolder)):
		DirAccess.make_dir_absolute(ProjectSettings.globalize_path(localFolder));
		return;
	if not (FileAccess.file_exists(saveLocation) and FileAccess.file_exists(activeTabLocation)):
		return;
	
	var fa = FileAccess.open(saveLocation, FileAccess.READ);
	var files := fa.get_as_text().split('\n');
	fa.close()
	
	fa = FileAccess.open(activeTabLocation, FileAccess.READ);
	var activeTab := fa.get_8()
	fa.close();
	
	panel._load_files(files);
	panel.tab_container.current_tab = activeTab;
	
	
	
	

	
