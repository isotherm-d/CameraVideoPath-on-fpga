# Task 1 / 3 / 5 development (v26)

Baseline v25: 4795a67. Camera and output remain 1280x720 at 30 fps.

Phase 0: centred RAW interpolation with Bayer reflection padding, complete bottom/right drain, synchronous FIFO and stream identity adapter. RGB nine-neighbour and all-four-border Bayer tests pass; existing ten camera/colour/network regressions pass. Functional branch: feature/task135.

Remaining: configuration transactions, seven image modes and OSD, AE/AWB, metadata/latency, classifier adapters, place-and-route and physical validation. No v26 bitstream or hardware claim yet.
