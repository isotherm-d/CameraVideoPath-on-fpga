# CellNet32 retired classifier sources

This standalone center480 CellNet32 path is archived for historical reference.
Its model files and the modules excluded from the current YOLO synthesis are
kept here. The mainboard `.al` project references these six disabled files by
relative path; the file contents were moved without RTL edits.

`cvp_cell_tracks.v` and `cvp_cell_label.v` remain in the mainboard's
`user_source/hdl_source/classify/` directory because the current project and
regressions still include them. The current detector and classifier are the
YOLO-style WBC model described in the root README and `docs/` reports.

The physical source hash report records build-time paths from before this
relocation. The archived source contents are unchanged; this cleanup did not
rebuild or replace the programmed bitstream.
