# v30 板测基准

来自用户确认上板功能无误的无 DSI 版本。仅改模块名；style 的 median 引用也指向冻结的旧实现。作为后续优化的独立差分基准，不参与 FPGA 工程综合。

`cvp_proc_v30_gold.v` 保留原 cvp_dpc.BYPASS=1 例化，用于验证当前主路径内置四拍旁路。原模块名还原后的哈希与 v30 manifest 一致；其引用的独立 cvp_dpc.v 也已核对与 v30 相同。测试比较所有输出以及每拍 RAW、valid 和 SOF，覆盖七模式、帧重启、空洞及异步复位。
