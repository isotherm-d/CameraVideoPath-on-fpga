# Task 1 / 3 / 5 development (v26)

Baseline v25: 4795a67. Branch: feature/task135. Camera/output: 1280x720 at30fps.

Implemented: centred complete Bayer/RGB frames and borders; unified128-bit pixel stream; seven image modes and OSD; frame-atomic configuration with acknowledgements/readback; AE, protected AWB and optional auto levels; sensor request/ack bridge; frame identities, telemetry and latency time mapping; clean-image output, double patch buffers and classification result hooks; v26 PC viewer and integration documentation.

Validation:12 newRTL tests,10 baselineRTL tests,27 Python tests, independent Ethernet CRC/IPv4/UDP verification and hidden Tk control smoke passed. Actual routed setup WNS0.109ns, hold0.020ns, both TNS0. Slice15410/21216, ERAM54/108, DSP10/40.

Physical acceptance: all seven modes and runtime quality controls checked in one scene after SW1. Continuous reception 1800.6s, 53953frames, 29.964fps, complete100.000%, with no reported stream/I2C errors during stress. Release: releases/v26.

Pending cooperative checks: physical mode keys, two-illuminant WB precision and AE light-step convergence. DSI/HDMI/optical latency unverified. No real ROI detector, trained model or LeNet core is connected. Long-run settings are original mode, manual exposure and preset WB; no claim of30minutes in each automatic mode.

See V26开发与接口说明.md and V26队友挂接示例.md. v24/v25 and the earlier candidate remain available. Unrelated local user edits are excluded. No GitHub push is performed by this release step.
