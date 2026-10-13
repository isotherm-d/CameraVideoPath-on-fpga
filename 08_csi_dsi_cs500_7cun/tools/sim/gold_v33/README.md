# v33 冻结基准

这里保存 PID 修改前的四个模块。只重命名模块及其内部引用为 `_v33_gold`，包括 advanced 文件内的 stream health 模块，以便与当前实现同时仿真。恢复这些名字并将 Windows CRLF 换行还原为 LF 后，源码 SHA256 与本目录 manifest 以及 v33 发布 manifest 一致。

旧 AE 与平滑测试明确使用冻结模块，记录旧控制策略；当前 PID 由 `tb_v26_ae_pid` 和 `tb_v26_pid_pipeline` 独立验证。新旧 AE 的响应有意改变，不宣称等价。`tb_v26_gain_total` 在数字增益为 1 倍时逐拍比较冻结 gain 模块，并以独立标量计算检查新增益范围。流错误恢复对比使用 gold_v32 advanced，并引用这些原版 AE、gain、sensor bridge 模块。
