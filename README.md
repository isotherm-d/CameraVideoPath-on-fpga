# CameraVideoPath-on-fpga

当前版本：**v27**。基于 MLKPAI-F02 / PH1P35 和 SC500CS 的 1280×720@30fps 相机图像处理工程。

## v27 下载与使用

- [v27 比特流](releases/v27/camera_to_dsi_display_v27.bit)
- [发布记录、资源与验证范围](releases/v27/README.md)
- [阈值操作、白平衡与 I2C 说明](08_csi_dsi_cs500_7cun/V27优化与阈值说明.md)
- [统一像素流与分类接口](08_csi_dsi_cs500_7cun/V26开发与接口说明.md)
- [队友挂接示例](08_csi_dsi_cs500_7cun/V26队友挂接示例.md)

TD 选择 PROGRAM_SRAM 加载 v27，比特流断电后丢失。电脑网卡为 192.168.1.100/24，连接板端网口后双击工程 tools/打开收图窗口.bat。收图 UDP6000、控制 UDP6001、状态 UDP6002，只打开一个收图程序。

v27 增加边缘/素描独立高低阈值和线宽，优化弱轮廓与自动白平衡，修复中文问号，并增加摄像头启动重试与分类 I2C 诊断。原图标定和统一分类挂接接口保留。

## 验证结果

28 项 RTL、35 项 Python 测试通过；七模式轮换、AE/AWB 开启运行 5 分钟，平均 29.965fps、完整率100%。两次 SRAM 热重载未按 SW1，初始化错误0。布线 setup WNS0.107ns、hold WNS0.020ns、TNS0。

Slice17359/21216（81.82%）、ERAM66/108、DSP10/40。真实 LeNet 核心尚未接入，模型挂接后需要重新评估资源和时序。断电 Flash 启动、两光源精度和 DSI/HDMI 未列入本轮验收。详见发布记录。

## 历史版本

- [v26 发布文件](releases/v26/README.md)
- [v25 发布文件](releases/v25/README.md)
- [v24 标签](https://github.com/isotherm-d/CameraVideoPath-on-fpga/tree/v24)

恢复 v26 时下载对应比特流、短按 SW1，运行 tools/打开v26收图窗口.bat。旧版本及提交历史保留。
