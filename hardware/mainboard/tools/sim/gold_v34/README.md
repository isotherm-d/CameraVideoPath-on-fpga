# Frozen v34 PID baseline

The original controller is byte-identical to the source hash in `old/releases/v34-candidate/manifest.json`. Only the module identifier is renamed to `cvp_ae_control_v34_gold` so the v34 and current controllers can run in one simulation. The manifest records both hashes.

`tb_v26_pid_timing.v` compares accepted requests and committed PID state after calculations finish, using common frame measurements and two-frame feedback. The new calculation has additional clock stages, so busy flags and output request cycles are intentionally not compared cycle by cycle.
