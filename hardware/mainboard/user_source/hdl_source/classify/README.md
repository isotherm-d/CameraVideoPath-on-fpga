# Mainboard compatibility RTL

`cvp_cell_tracks.v` and `cvp_cell_label.v` remain at this path because the
mainboard TD project and regression scripts still include them. They are kept
byte-for-byte for the released hardware source set.

The retired standalone CellNet32 inference modules and their model files are
archived in [`old/cellnet32/classify`](../../../../../old/cellnet32/classify/README.md).
The current detection and classification implementation is under the sibling
`yolo/` RTL directory.
