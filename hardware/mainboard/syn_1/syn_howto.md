syn_1 run 目录说明
==================
settings.cfg + DefaultFlow.tcl(TD 自带) = 本地 TD 6.2.1 全流程跑 detect-integration 分支。
跑法：cd syn_1 && E:/TD_6.2.1/bin/td_commands_prompt.exe E:/TD_6.2.1/doc/scripts/DefaultFlow.tcl
产物（.bit/.db/log）不入库。
要求：detect-integration 分支；.al 必须从 td_project 同步（或由 TD 从 .prj 再生）。
