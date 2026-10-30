package diskfull

// Each platform_<os>.odin file provides:
//
//   PATH_SEP, FILE_MANAGER, WINDOW_FLAGS, FONT_CANDIDATES
//   PERMISSION_HINT, DENIED_HINT, HIDDEN_HINT, PLATFORM_NOTES
//   default_root, absolute_path, volume_info, path_id, scan_dir
//   reveal_in_file_manager, open_folder, ignore_child_exits, to_nfc

Volume_Info :: struct {
	total:     i64,
	used:      i64,
	free:      i64, // available to the user
	mount:     string, // where the volume holding the path is mounted
	container: string, // storage backing the volume; mounts sharing it are scanned too ("" = unknown)
}
