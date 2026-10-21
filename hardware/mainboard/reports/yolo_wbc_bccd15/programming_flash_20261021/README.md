# PH1P35 主板 Flash 写入记录

目标模型为 `wbc_bccd160_devcam_20261021`，候选 bit SHA256 为 `5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。

2026-10-21 本机 TD6.2 使用 PH1P35MDG324、SPI Flash ID `c8 65 18` 和 `-v` 选项执行写入。设备校验成功、Flash 扇区擦除开始，并进入逐页编程/校验阶段；随后报 `PRG-8000 ERROR: get tdo buffer failed`，Tcl catch=1。该次工具操作未通过，不能据此确认 Flash 内容或冷启动状态。

用户之后表示“flash我自己烧录好了”。这条实板烧录成功信息按用户反馈记录，未由本机读取其烧录工具日志独立验证，也未向用户确认手动烧录文件的 SHA，因此不将候选 bit 哈希作为已核实的 Flash 内容。

本机的完整 TD6.2 日志和 Tcl 命令留在本地工作目录；`agent_failed_attempt_summary.json` 保存了去除本机路径后的失败摘要与日志 SHA，`user_reported_manual_flash.json` 保存用户后续反馈。SRAM 的成功下载记录在 `../programming/programming.json`。
