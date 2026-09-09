# HyperOS 助理切换

HyperOS Assistant Switcher · 中文界面 · Magisk / SukiSU 模块

将 HyperOS 的**长按电源键 AI 入口**切换为 Android 系统默认数字助理，或恢复超级小爱。适用于 Magisk / SukiSU 模块管理器，使用标准 `action.sh` 提供一键切换。

模块仅管理入口。请自行在系统中选择默认数字助理，例如 Gemini、ChatGPT 或其他支持 Android 数字助理角色的应用。模块不会修改默认助理角色、安装/冻结应用，也不会写入某个应用的包名。

## 原理与适用范围

使用以下两项设置，除此之外不修改系统设置：

| 模式 | `system`（用户 0）`long_press_power_key` | `global` `power_button_long_press` |
| --- | --- | --- |
| 系统默认数字助理 | `launch_google_search` | `0` |
| 超级小爱 | 删除此键 | `1` |

`launch_google_search` 是 HyperOS 使用的动作名称。在题述已验证的 HyperOS 3 / Android 16 环境中，这个组合会恢复默认 Assistant 入口；该字符串不代表模块将默认助理设置成 Google。

- 使用系统 `settings` 命令；不修改 framework，不使用 Hook / Zygisk，不挂载系统文件，不修改 SELinux 策略。
- 安装要求 Android 12+。具体行为依赖 ROM，**已有命令验证范围为 HyperOS 3 / Android 16**；其他版本需要真机确认。Android 版本检查只是安装门槛。
- 固定操作系统主用户 **user 0**，与已验证命令一致。`global` 设置对整台设备共享；未提供工作资料、第二空间或多用户独立切换功能。
- 两项设置读回成功只证明配置已写入。锁屏限制、助理是否支持相应角色、ROM 实际分发逻辑，仍需要按测试步骤确认。

## 安装

1. 先在系统的「设置 → 应用 → 默认应用 → 数字助理应用」中选择助理。菜单名称随 ROM 不同，可搜索「数字助理」或「默认应用」。
2. 从 [最新版本](https://github.com/Systina12/HyperOS-Assistant-Switcher/releases/latest) 下载 `HyperOS-Assistant-Switcher-v1.0.0.zip`。也可自行构建：

   ```console
   python tools/build.py
   ```

   输出为 `dist/HyperOS-Assistant-Switcher-v1.0.0.zip`，同时生成 `.zip.sha256` 校验文件。Python 3.10+ 即可，无第三方依赖。不要直接把 GitHub 的源码 ZIP 当作模块安装。

3. 在 **Magisk 或 SukiSU 管理器 → 模块 → 从本地安装** 中选择生成的 ZIP，然后重启。安装入口为管理器；不提供 Recovery 安装器。
4. 首次安装默认启用「系统默认数字助理」。安装脚本本身不修改两项设置；首次开机校正或第一次手动切换前会备份原始值。升级保留之前保存的模式与守护配置。
5. 长按电源键，确认系统所选数字助理出现。

日常使用只需点击模块的「操作 / Action」按钮，无需输入命令或选择菜单。默认只做开机校正，完成后退出。旧版 Magisk 如果没有操作按钮，可使用下方 CLI。

## 一键切换与状态

点击模块操作按钮，直接显示当前入口和切换结果。模块名称、安装提示、操作提示及文档均为中文。

```text
HyperOS 助理切换
--------------------------
当前入口：超级小爱
切换成功：系统默认数字助理（两项设置已读回验证）
请在系统“默认应用 / 数字助理应用”中选择助理，然后长按电源键测试。
```

- 当前两项设置属于某个标准模式时，Action 切到另一个模式。
- 当前是混合值或自定义组合时，本次 Action **恢复已保存的选择**，首次使用时恢复系统默认数字助理。输出会说明这种情况。
- 要直接修复 HyperOS 回写而不进行切换，用 `reapply`；要明确指定目标，用 `set assistant` 或 `set xiaoai`。
- 任何一步失败或读回不一致，会尝试恢复操作前的两项值；保存模式只在验证成功后更新。回滚无法验证时会明确报错。

## CLI

在手机终端执行；电脑也可先进入 `adb shell` 再执行：

```sh
su
sh /data/adb/modules/hyperos_assistant_switcher/control.sh status
sh /data/adb/modules/hyperos_assistant_switcher/control.sh toggle
sh /data/adb/modules/hyperos_assistant_switcher/control.sh set assistant
sh /data/adb/modules/hyperos_assistant_switcher/control.sh set xiaoai
sh /data/adb/modules/hyperos_assistant_switcher/control.sh reapply
```

`status` 只读，显示实际设置、保存模式、守护状态，便于排查 HyperOS 回写；不切换、不建立原始备份。它报告的是设置状态，不推断当前选中的助理应用或硬件启动结果。

## HyperOS 重写设置时

默认 `service.sh` 等待 `sys.boot_completed=1`（最长等待 180 秒），随后约在 **0、10、30、60、120 秒**检查保存模式并按需恢复。默认不会一直运行轮询进程。每次校正都会在锁内重新读取保存模式，因此用户在这期间通过 Action 切换后，后续校正会采用新选择。

如果某个 ROM 会在进入小爱设置、锁屏或使用过程中重写这些键，可开启守护：

```sh
# 开启，默认每 60 秒检查
sh /data/adb/modules/hyperos_assistant_switcher/control.sh guard on

# 自定义间隔，允许 60–3600 秒
sh /data/adb/modules/hyperos_assistant_switcher/control.sh guard 120

# 关闭持续守护，仍保留开机有限次校正
sh /data/adb/modules/hyperos_assistant_switcher/control.sh guard off
```

开启会保存配置并请求启动后台脚本；若已有脚本运行则复用现有任务。新任务先执行同样的有限次校正，再进入低频检查。两项设置已经匹配时不会重复写入；配置和日志也按需更新。

守护属于周期检查，被重写到下一次检查之间仍有窗口。禁用模块、标记卸载或关闭守护后，正在等待的循环会在下次检查时退出；不会为了立即退出而误杀其他进程。守护也会保持用户选择的「超级小爱」模式。

诊断日志：

```sh
cat /data/adb/hyperos_assistant_switcher/service.log
```

日志采用约 32 KiB 的轮转阈值，最多保留当前与上一份；不读取聊天内容或助理账号信息。

## 禁用、恢复和卸载

**仅禁用模块不会撤销已写入的系统设置。** 它只停止后续校正。可以先 Action 切回超级小爱，再禁用；也可以恢复首次接管前的原始值并暂停模块：

```sh
sh /data/adb/modules/hyperos_assistant_switcher/control.sh restore
```

`restore` 成功后会创建模块 `disable` 标记，避免后台再覆盖恢复结果。之后可在管理器中卸载；如要继续使用，重新启用并重启。

正常卸载会恢复**首次接管前**两项设置的原始值，包含“键不存在”的状态。因此，原本就是系统数字助理时，卸载后仍是该模式。

如果管理器在开机早期执行卸载，SettingsProvider 可能还不可用。此时卸载脚本保留备份，并建立 `/data/adb/service.d/hyperos_assistant_switcher_restore.sh` 延后恢复任务。恢复脚本和所需函数保存在独立状态目录，模块目录删除后仍可运行；成功后自动删除恢复任务、脚本、备份和模式配置，留下小体积诊断日志。失败会保留备份和任务供下次开机重试。重新安装会取消旧的待恢复任务，并保留原始备份。

若恢复任务未完成，可在系统启动后查看日志，并手动执行仍保留的恢复脚本：

```sh
sh /data/adb/hyperos_assistant_switcher/restore.sh
```

原始备份位于 `/data/adb/hyperos_assistant_switcher/original`，仅 root 可读。请不要在恢复完成前删除它。

如需直接应用题述的已知小爱组合，先禁用本模块并重启以停止校正，再执行：

```sh
settings --user 0 delete system long_press_power_key
settings put global power_button_long_press 1
```

## 结构、测试与贡献

```text
module/
  module.prop       模块元数据
  skip_mount        无系统目录挂载
  customize.sh      安装检查、权限、升级时取消旧恢复任务
  common.sh         设置读写、验证、备份、事务与锁
  action.sh         管理器 Action
  control.sh        状态与 CLI
  service.sh        开机校正、可选低频守护
  uninstall.sh      卸载恢复与延后恢复调度
  restore.sh        不依赖模块目录的延后恢复执行器
tools/build.py      可复现 ZIP 与 SHA-256 构建
tests/test_module.py 主机端真实 shell 脚本集成测试
docs/              实现说明与真机测试清单
.github/workflows/ci.yml  dash / BusyBox ash / mksh / ShellCheck / ZIP 构建
```

主机端测试：

```console
python -m unittest discover -s tests -v
```

Windows 使用 Git for Windows 附带的 `dash`；Linux 默认使用 `dash` 或 `sh`。CI 还运行 BusyBox ash、mksh 和 ShellCheck，并模拟 Magisk / SukiSU 的 Action 调用方式。测试运行真实模块脚本，用临时设置服务模拟 Android，不会连接或修改手机。

详见 [安装后测试与故障排查](docs/TESTING.md) 和 [实现与状态说明](docs/ARCHITECTURE.md)。主机测试不能替代 Magisk / SukiSU 与各个 ROM 的真机测试。

仓库：[Systina12/HyperOS-Assistant-Switcher](https://github.com/Systina12/HyperOS-Assistant-Switcher)。许可证为 [MIT](LICENSE)。
