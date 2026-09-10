# HyperOS 助理切换

HyperOS Assistant Switcher · Magisk / SukiSU 模块

将 HyperOS 的**长按电源键 AI 入口**切换为 Android 系统默认数字助理。适用于 Magisk / SukiSU 模块管理器，使用标准 `action.sh` 提供一键切换。

模块仅管理入口。请自行在系统中选择默认数字助理，例如 Gemini、ChatGPT 或其他支持 Android 数字助理角色的应用。

## 原理与适用范围

使用以下两项设置，除此之外不修改系统设置：

| 模式 | `system`（用户 0）`long_press_power_key` | `global` `power_button_long_press` |
| --- | --- | --- |
| 系统默认数字助理 | `launch_google_search` | `0` |
| 超级小爱 | 删除此键 | `1` |

在hyperOS3的小米13上经过测试

## 一键切换

点击模块操作按钮，直接显示当前入口和切换结果。

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

## 禁用、恢复和卸载

**仅禁用模块不会撤销已写入的系统设置。** 可以先 Action 切回超级小爱，再禁用；也可以恢复首次接管前的原始值并暂停模块：

```sh
sh /data/adb/modules/hyperos_assistant_switcher/control.sh restore
```

`restore` 成功后会创建模块 `disable` 标记，避免后台再覆盖恢复结果。之后可在管理器中卸载；如要继续使用，重新启用并重启。




