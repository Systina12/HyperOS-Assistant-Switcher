# 安装后测试与故障排查

## 验证范围

题述命令已经在 HyperOS 3 / Android 16 验证。仓库的自动测试覆盖真实 shell 脚本的控制流程、持久状态和故障恢复；Android SettingsProvider 由本地模拟器代替。**本仓库测试结果不代表已完成模块真机安装或硬件入口测试。**

建议分别记录以下环境的真机结果，不根据 Android 版本号直接推断支持：

| ROM | Root 管理器 | 核心验证 |
| --- | --- | --- |
| HyperOS 3 / Android 16 | SukiSU（记录管理器 / 内核版本） | 安装、Action、重启、守护、卸载 |
| HyperOS 3 / Android 16 | Magisk（记录版本） | 安装、Action 或 CLI、重启、卸载 |
| 其他 HyperOS / Android | 任一受支持管理器 | 两个设置键与硬件分发是否仍遵循该机制 |

## 连接与基线

电脑先执行 `adb shell`，然后在设备 shell 中取得 root：

```sh
su
id
getprop ro.mi.os.version.name
getprop ro.build.version.release
getprop ro.build.version.sdk
am get-current-user
settings --user 0 get system long_press_power_key
settings get global power_button_long_press
```

确认 `id` 显示 `uid=0`；建议在主用户 `0` 测试。两个 `get` 返回 `null` 通常代表键不存在，但也可能是字面量 `null`；模块的原始备份会区分二者。安装前记录两项值和当前硬件入口。

## 基本功能

1. 在系统默认应用中选定一个支持数字助理角色的应用。
2. 安装构建 ZIP 并重启。约等待开机后两分钟，再检查：

   ```sh
   sh /data/adb/modules/hyperos_assistant_switcher/control.sh status
   settings --user 0 get system long_press_power_key
   settings get global power_button_long_press
   ```

   预期系统值 `launch_google_search`、全局值 `0`。长按电源键应启动系统所选数字助理。

3. 点击模块 Action。预期输出从系统默认数字助理切换为超级小爱；系统键不存在，全局值 `1`。长按确认小爱入口。
4. 再次点击 Action。预期恢复系统默认数字助理。
5. **只在系统中更换默认数字助理**，不修改模块模式。再次长按电源键，应由新选择的助理处理。这一步验证模块没有绑定 ChatGPT、Gemini 或任何其他包。
6. 分别测试解锁、锁屏和熄屏状态，记录 ROM / 应用的限制。

若管理器没有 Action 按钮，使用 `control.sh toggle`，并记录所用管理器版本。

## 开机持久性与系统回写

### 保存模式与开机期间的 Action

1. `control.sh set xiaoai` 后重启，确认保持小爱。
2. `control.sh set assistant` 后重启，确认保持系统默认助理。
3. 开机后两分钟内通过 Action 切换一次；后续开机校正应保持这次新选择。

### 受控模拟回写

先选择 assistant 并开启守护，然后用 root shell 模拟小米服务重新绑定入口：

```sh
sh /data/adb/modules/hyperos_assistant_switcher/control.sh set assistant
sh /data/adb/modules/hyperos_assistant_switcher/control.sh guard on
settings --user 0 delete system long_press_power_key
settings put global power_button_long_press 1
sh /data/adb/modules/hyperos_assistant_switcher/control.sh status
```

预期立即出现“实际设置与保存模式不一致”，下一次检查后恢复 assistant。守护启动最初两分钟使用有限次校正节奏，之后每 60 秒检查。恢复过程可在 `service.log` 中确认。

随后关闭守护，等待开机校正阶段结束，再模拟同样回写。应保持回写结果，直到执行 `reapply`、Action 或下一次重启：

```sh
sh /data/adb/modules/hyperos_assistant_switcher/control.sh guard off
sh /data/adb/modules/hyperos_assistant_switcher/control.sh reapply
```

使用系统小爱设置页面、锁屏或其他能触发实际回写的操作重复测试，记录触发步骤与修复延迟。

## 禁用与卸载

1. 禁用模块，等待正在睡眠的守护结束或重启。确认模块不再重写设置；已设置的入口会保留。
2. 重新启用并重启，再执行 `control.sh restore`。预期恢复首次接管前的原始两项值，并创建 `disable` 标记。
3. 在管理器卸载并按管理器要求重启，确认原始值被恢复。不要一律要求变成小爱：首次接管前若为其他自定义值或默认助理，应恢复那些原始值。
4. 验证原本不存在的键恢复为不存在，原本存在的自定义值保留。
5. 检查延迟恢复任务在成功后已移除：

   ```sh
   ls /data/adb/service.d/hyperos_assistant_switcher_restore.sh
   cat /data/adb/hyperos_assistant_switcher/service.log
   ```

   成功后 `ls` 应提示文件不存在。日志目录保留用于排查。

## 故障定位

| 现象 | 检查与处理 |
| --- | --- |
| 显示 assistant，但仍启动小爱 | 确认 user 0、系统默认助理设置、两项实际值；记录 ROM 完整版本，并验证题述原始命令在此 ROM 上是否有效 |
| 默认助理入口无响应 | 先从系统其他入口测试该助理，确认应用具备数字助理角色支持与锁屏权限 |
| 设置很快被改回 | 执行 `status` 查看实际 / 保存差异，开启低频守护并记录触发回写的操作 |
| 两项值混合 | `reapply` 恢复保存选择，或 `set assistant` / `set xiaoai` 明确选择 |
| Settings 服务不可用 | 等待开机完成后重试；查看日志。不会把读取失败当成空值继续切换 |
| 已回滚 | 目标写入或保存失败，模块已验证恢复操作前的值；排查 ROM 权限与回写 |
| 回滚未能验证 | 查看实际值，检查 root 权限和 ROM 行为，再明确设置目标；首次备份仍保留 |
| 操作锁忙 | 等待并重试；如前次被强制终止，重启清除 `/dev` 中的锁 |
| 卸载后任务仍存在 | 读取日志；系统启动后运行独立状态目录中的 `restore.sh`。失败时保留备份继续排查 |

## 主机测试

```console
python -m unittest discover -s tests -v
python tools/build.py
```

自动测试关注：

- 两个标准模式、混合状态、明确设置与幂等重入。
- Magisk 的目录内相对路径调用、SukiSU 的绝对路径调用及简洁中文输出。
- Action 锁等待在 SukiSU 执行窗口内返回；失败退出码正常传递。
- 无关设置的多行内容不阻断操作，目标值多行则在修改前安全拒绝。
- 只允许两个目标键，system 固定 user 0，不修改数字助理角色。
- 读取失败、静默写入失败、第二项写入失败、持久保存失败和回滚。
- 精确保留不存在、空值、字面量 `null` 和任意单行原始值。
- 不执行状态文件中的 shell 文本。
- 有限次开机校正、等待超时、开机中 Action、新旧模式并发。
- 可选守护、退出标记、锁竞争。
- 普通卸载、模块目录删除后的延迟恢复、失败后下次启动重试、重新安装取消旧任务。
- ZIP 根目录布局、权限、LF 换行、校验和与可复现构建。

GitHub Actions 会分别使用 dash、BusyBox ash、mksh 运行集成测试并进行 ShellCheck。CI 产物可从 Actions 页面下载；上传的构建产物并不自动声明真机兼容性。
