# Task 1 / 3 / 5 development (v27)

Baseline v25: 4795a67. Branch: feature/task135. Camera/output: 1280x720 at30fps.

Implemented: centred complete Bayer/RGB frames and borders; unified128-bit pixel stream; seven image modes and OSD; frame-atomic configuration with acknowledgements/readback; AE, protected AWB and optional auto levels; sensor request/ack bridge; frame identities, telemetry and latency time mapping; clean-image output, double patch buffers and classification result hooks; v26 PC viewer and integration documentation.

Validation:12 newRTL tests,10 baselineRTL tests,27 Python tests, independent Ethernet CRC/IPv4/UDP verification and hidden Tk control smoke passed. Actual routed setup WNS0.109ns, hold0.020ns, both TNS0. Slice15410/21216, ERAM54/108, DSP10/40.

Physical acceptance: all seven modes and runtime quality controls checked in one scene after SW1. Continuous reception 1800.6s, 53953frames, 29.964fps, complete100.000%, with no reported stream/I2C errors during stress. Release: releases/v26.

Pending cooperative checks: physical mode keys, two-illuminant WB precision and AE light-step convergence. DSI/HDMI/optical latency unverified. No real ROI detector, trained model or LeNet core is connected. Long-run settings are original mode, manual exposure and preset WB; no claim of30minutes in each automatic mode.

See V26开发与接口说明.md and V26队友挂接示例.md. v24/v25 and the earlier candidate remain available. Unrelated local user edits are excluded. No GitHub push is performed by this release step.

## V27 quality update

Independent edge/sketch low/high thresholds and strokes; Gaussian/Sobel/local weak-edge connection; preset-anchored protected AWB; Unicode overlay; classified I2C diagnostics, bounded retries and startup frame qualification implemented. Original calibrated image and public pixel/NN interfaces retained.

Passed6newRTL+12v26RTL+10baselineRTL,35Python tests, bothpacketCRC/IP/UDP checks, mocked/realhiddenGUI checks. Actualroute: setup0.107ns,hold0.020ns,TNS0; Slice17359/21216(81.82%),ERAM66/108,DSP10/40.

Two warm SRAM reloads without SW1: initializationerrors0,retries0. AE/AWB enabled and7modesrotated for300.2s,8996frames,29.965fps,complete100%,no reportedstream/I2Cerrors. One-sceneautoWB344/256/451. Release:releases/v27; seeV27优化与阈值说明.md.

NoFlashwrite orcoldFlashbootvalidation. Physicalmodekeys, two-illuminantprecision, DSI/HDMI andrealLeNet remainunverified. Largerresourceusage requiresfreshmodelintegration/timingassessment. v26retained; noGitHubpush.
