# 实现与状态说明

## 入口契约

运行脚本只依赖 Android 提供的 `settings`、`getprop` 和基础 shell 工具。模块管理器提供的 BusyBox ash、Android `sh` 均为目标运行环境。运行时没有 Python、Node、网络请求、原生二进制、框架替换、系统挂载或 Hook 依赖。

采用 Magisk / KernelSU 系列共享的模块文件约定：`customize.sh` 安装，`service.sh` 启动，`action.sh` 用户操作，`uninstall.sh` 移除。SukiSU 使用相同的模块入口约定。没有仅适用于某个管理器的 Action 工具依赖。ZIP 根目录直接放置 `module.prop` 与脚本。

操作按钮只显示“当前入口 → 切换结果”，通过一次调用进入公共切换逻辑。Magisk 当前实现为在模块目录中执行 `sh ./action.sh`；SukiSU 为 BusyBox 执行 Action 的绝对路径。测试覆盖两种调用、相对路径和中文输出；使用 POSIX shell 语法，同时在 dash、BusyBox ash 和 mksh 下验证。

安装定制脚本由管理器 source，使用其 `ui_print`、`abort`、`set_perm`、`set_perm_recursive`，不调用 `exit`。没有 `post-fs-data.sh`，避免在早期阻塞阶段访问 SettingsProvider。无需 Zygisk 或挂载用的 metamodule。

参考规范：

- [Magisk Developer Guides](https://topjohnwu.github.io/Magisk/guides.html)
- [KernelSU Module Guide](https://kernelsu.org/guide/module.html)
- [SukiSU-Ultra 源码](https://github.com/SukiSU-Ultra/SukiSU-Ultra)

## 最小设置范围

所有系统表读写都显式指定 `--user 0`；全局表保持设备级语义。代码不读写 `secure.assistant`、`voice_interaction_service` 或 RoleManager，不探测助理应用包名。

读状态优先通过 `settings get` 读取目标键，只有返回 `null` 时才查表区分“不存在”与字面量 `null`。这样不会被无关设置中的多行内容阻断操作。原始目标值若包含多行会拒绝修改，避免无法准确备份。设置列表只存在于当前进程内存，不整体写入日志；常见的“退出码 0 但输出异常”也按读取失败处理。

有效组合只有两种，其余均显示“自定义 / 不一致”。两个值的写入不是 Android 原子事务；程序通过串行化操作、事后读回和失败回滚实现尽可能一致的行为。外部 ROM 服务不遵守模块的锁，因此仍可能在两次设置命令之间或读回之后回写。可选守护用后续检查修复这种情况。

## 持久状态

位置：`/data/adb/hyperos_assistant_switcher`，目录权限 `0700`，文件默认 `0600`。

| 文件 | 含义 |
| --- | --- |
| `mode` | `assistant` / `xiaoai`；不存在时默认 `assistant` |
| `guard` | `off` 或 60–3600 的十进制秒数；不存在时默认 `off` |
| `original` | 首次接管前的两项值和存在标志 |
| `service.log`、`service.log.1` | 有界诊断日志 |
| `uninstalling` | 卸载恢复尚未完成，阻止模块继续校正 |
| `restore.sh`、`common.sh` | 仅在延后恢复时复制，避免依赖已删除模块 |

状态文件不会作为 shell 脚本加载，不使用 `eval`。模式和守护参数均经过枚举 / 范围校验。配置保存使用同目录临时文件 + `mv`，相同内容不重复写入。

`original` 是固定五行的纯数据格式：

```text
HAS_ORIGINAL_V1
<system 是否存在：0 或 1>
<system 原始值；不存在时为空行>
<global 是否存在：0 或 1>
<global 原始值；不存在时为空行>
```

例如标准小爱入口的备份：

```text
HAS_ORIGINAL_V1
0

1
1
```

升级和多次切换不会重写首次备份。备份缺失时在首次应用模式前建立；备份损坏时拒绝继续更改设置。

## 切换顺序

1. 确认 root、参数、模块未禁用 / 移除 / 正在卸载。
2. 获取操作锁，读取实际值，记录操作前快照。
3. 首次操作先持久备份；已存在的备份需通过格式验证。
4. 值不匹配时应用目标组合；读回两项并核对。
5. 成功后保存选择，输出成功结果。设置已经匹配时省略设置写入。
6. 任一步失败则恢复操作前快照并再次验证。保留之前的已保存选择，明确输出回滚是否成功。

Action 根据实际组合选择相反模式。实际组合不标准时恢复已保存模式，以便修复部分回写；CLI `set` 与 `reapply` 提供无歧义的操作。

## 并发与生命周期

操作锁为 `/dev/.hyperos_assistant_switcher/operation`，通过原子 `mkdir` 获取。后台任务最多等待 10 秒；操作按钮 / CLI 最多等待 3 秒，为 SukiSU 的 10 秒 Action 执行窗口留出返回结果的时间。Action、服务校正、安装时取消旧恢复任务、卸载与延后恢复都遵守同一把锁。锁内重新读取保存模式，不缓存开机时的旧选择。

后台单例锁为同一目录中的 `service`，防止多次 `guard on` 启动重复任务。正常退出、SIGINT、SIGTERM 都释放所持有的锁。不会“抢占”其他进程的锁，也不按不可靠的 PID 杀进程。SIGKILL / 进程崩溃可能残留锁，此时重启清空 `/dev` 即可；状态输出也提示后台锁可能属于已终止任务。

模块禁用或移除标记在每次操作前检查，等待开机校正时每 5 秒检查一次；守护休眠期间最多延迟一个配置间隔退出。禁用不恢复已写入的键，手动 `restore` 或卸载才恢复。

仅卸载时需要在模块目录之外建立短暂的 `service.d` 恢复入口。恢复执行器等待 Android 开机，最多等待 180 秒；然后最多尝试 6 次恢复、相邻尝试间隔 10 秒。若仍失败，任务保留至下一次启动。恢复成功后精确删除自己的任务与状态文件，保留诊断日志，不递归删除 `/data` 目录。

测试使用 `HAS_STATE_DIR`、`HAS_RUN_DIR`、`HAS_RESTORE_HOOK` 环境变量将路径重定向到临时目录；正常安装不需要设置这些变量。

## 已知边界

- 仅验证设置组合，不能从 shell 设置返回值证明某个 ROM 的电源键分发成功。
- 无法提供零延迟防回写，也不会与系统进程持续竞争写入。
- 硬件入口在上锁状态下能否调用助理，由 ROM 和助理应用决定。
- 命令执行中被 SIGKILL、系统断电或外部进程即时回写时，事务不能保证原子性。原始备份、保存模式、后续校正和卸载恢复提供恢复路径。
- 不自动切换活动 Android 用户。要支持多用户需单独验证每个 ROM 的用户路由和全局设置冲突。
