#!/system/bin/sh
# Shared by Magisk / SukiSU entry points. All configuration is data, never sourced.

HAS_STATE_DIR=${HAS_STATE_DIR:-/data/adb/hyperos_assistant_switcher}
HAS_RUN_DIR=${HAS_RUN_DIR:-/dev/.hyperos_assistant_switcher}
HAS_RESTORE_HOOK=${HAS_RESTORE_HOOK:-/data/adb/service.d/hyperos_assistant_switcher_restore.sh}
HAS_ERROR=
HAS_LOCKED=0

has_error() {
  HAS_ERROR=$*
  return 1
}

has_root() {
  [ "$(id -u)" = 0 ] || has_error '需要 root 权限。'
}

has_prepare() {
  umask 077
  if mkdir -p "$HAS_STATE_DIR" "$HAS_RUN_DIR" &&
    chmod 700 "$HAS_STATE_DIR" "$HAS_RUN_DIR"; then
    return 0
  fi
  has_error '无法创建模块状态目录。'
}

# The lock lives on /dev (tmpfs): a reboot clears a lock left by SIGKILL.
# Never steal a lock from another process, including during uninstall.
has_lock() {
  has_prepare || return 1
  HAS_LOCK_TIMEOUT=${1:-10}
  HAS_LOCK_WAIT=0
  until mkdir "$HAS_RUN_DIR/operation" 2>/dev/null; do
    [ "$HAS_LOCK_WAIT" -lt "$HAS_LOCK_TIMEOUT" ] || {
      has_error '另一个操作正在运行，或上次操作被强制终止；稍后重试，必要时重启。'
      return 1
    }
    sleep 1
    HAS_LOCK_WAIT=$((HAS_LOCK_WAIT + 1))
  done
  HAS_LOCKED=1
}

has_unlock() {
  if [ "$HAS_LOCKED" = 1 ]; then
    rmdir "$HAS_RUN_DIR/operation" 2>/dev/null
    HAS_LOCKED=0
  fi
}

has_active() {
  [ -f "$MODDIR/module.prop" ] && [ ! -e "$MODDIR/disable" ] &&
    [ ! -e "$MODDIR/remove" ] && [ ! -e "$HAS_STATE_DIR/uninstalling" ]
}

has_atomic_write() {
  [ ! -e "$1" ] || [ -f "$1" ] || {
    has_error "状态文件不是普通文件：$1"
    return 1
  }
  if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then return 0; fi
  if (umask 077; printf '%s\n' "$2" > "$1.tmp.$$") &&
    mv -f "$1.tmp.$$" "$1"; then
    return 0
  fi
  rm -f "$1.tmp.$$"
  has_error "无法保存文件：$1"
}

has_load_mode() {
  HAS_MODE=assistant
  if [ -f "$HAS_STATE_DIR/mode" ]; then
    HAS_MODE=$(cat "$HAS_STATE_DIR/mode") || {
      has_error '无法读取已保存模式。'
      return 1
    }
  fi
  case "$HAS_MODE" in
    assistant|xiaoai) return 0 ;;
    *) has_error 'mode 文件无效；请使用 control.sh set assistant 或 set xiaoai 修复。' ;;
  esac
}

has_load_guard() {
  HAS_GUARD=off
  if [ -f "$HAS_STATE_DIR/guard" ]; then
    HAS_GUARD=$(cat "$HAS_STATE_DIR/guard") || return 1
  fi
  case "$HAS_GUARD" in
    off) return 0 ;;
    ''|*[!0-9]*|?????*) has_error 'guard 必须是 off 或 60–3600 秒。'; return 1 ;;
  esac
  # Reject leading zeroes so shell arithmetic never interprets octal values.
  case "$HAS_GUARD" in 0*) has_error 'guard 秒数不能包含前导零。'; return 1 ;; esac
  [ "$HAS_GUARD" -ge 60 ] && [ "$HAS_GUARD" -le 3600 ] ||
    has_error 'guard 间隔必须在 60–3600 秒之间。'
}

has_mode_label() {
  case "$1" in
    assistant) printf '%s' '系统默认数字助理' ;;
    xiaoai) printf '%s' '超级小爱' ;;
    *) printf '%s' '自定义 / 不一致（可能被系统重写）' ;;
  esac
}

# Read only the target value. A trailing sentinel preserves its exact newlines.
# Consult the table only for "null", which can mean either a missing key or data.
has_read_setting() {
  if [ "$1" = system ]; then
    HAS_REPLY=$(settings --user 0 get system "$2" 2>&1 && printf '.')
  else
    HAS_REPLY=$(settings get global "$2" 2>&1 && printf '.')
  fi
  HAS_READ_RC=$?
  [ "$HAS_READ_RC" = 0 ] || { has_error "读取 $1 设置失败：$HAS_REPLY"; return 1; }
  HAS_EOL='
'
  case "$HAS_REPLY" in
    *"$HAS_EOL".) HAS_READ_VALUE=${HAS_REPLY%"$HAS_EOL".} ;;
    *) has_error '设置命令返回格式异常，已取消操作。'; return 1 ;;
  esac
  case "$HAS_READ_VALUE" in
    *"$HAS_EOL"*|Error:*|Exception*|java.*Exception*|android.*Exception*|SecurityException*|"Can't find service"*|"cmd: "*|"settings: "*)
      has_error '无法读取目标设置或目标值包含多行，已取消操作。'
      return 1
      ;;
  esac
  HAS_READ_PRESENT=1
  [ "$HAS_READ_VALUE" = null ] || return 0
  if [ "$1" = system ]; then
    HAS_LIST=$(settings --user 0 list system 2>&1) || {
      has_error "读取 system 设置失败：$HAS_LIST"
      return 1
    }
  else
    HAS_LIST=$(settings list global 2>&1) || {
      has_error "读取 global 设置失败：$HAS_LIST"
      return 1
    }
  fi
  HAS_READ_PRESENT=0
  HAS_READ_VALUE=
  while IFS= read -r HAS_LINE; do
    case "$HAS_LINE" in
      '') ;;
      Error:*|Exception*|java.*Exception*|android.*Exception*|SecurityException*|"Can't find service"*|"cmd: "*|"settings: "*)
        has_error "Settings 服务尚未就绪或输出异常：$HAS_LINE"
        return 1
        ;;
      "$2="*)
        [ "$HAS_READ_PRESENT" = 0 ] || {
          has_error "设置输出包含重复键：$2"
          return 1
        }
        [ "${HAS_LINE#*=}" = null ] || {
          has_error '读取期间设置发生变化，请重试。'
          return 1
        }
        HAS_READ_PRESENT=1
        HAS_READ_VALUE=null
        ;;
      # Unrelated settings may contain multiline values. Do not parse them.
      *) ;;
    esac
  done <<EOF
$HAS_LIST
EOF
}

has_read_settings() {
  has_read_setting system long_press_power_key || return 1
  HAS_SYSTEM_PRESENT=$HAS_READ_PRESENT
  HAS_SYSTEM_VALUE=$HAS_READ_VALUE
  has_read_setting global power_button_long_press || return 1
  HAS_GLOBAL_PRESENT=$HAS_READ_PRESENT
  HAS_GLOBAL_VALUE=$HAS_READ_VALUE
  HAS_CURRENT=custom
  if [ "$HAS_SYSTEM_PRESENT" = 1 ] &&
    [ "$HAS_SYSTEM_VALUE" = launch_google_search ] &&
    [ "$HAS_GLOBAL_PRESENT" = 1 ] && [ "$HAS_GLOBAL_VALUE" = 0 ]; then
    HAS_CURRENT=assistant
  elif [ "$HAS_SYSTEM_PRESENT" = 0 ] &&
    [ "$HAS_GLOBAL_PRESENT" = 1 ] && [ "$HAS_GLOBAL_VALUE" = 1 ]; then
    HAS_CURRENT=xiaoai
  fi
}

has_write_setting() {
  if [ "$3" = 1 ]; then
    if [ "$1" = system ]; then
      HAS_WRITE_OUTPUT=$(settings --user 0 put system "$2" "$4" 2>&1)
    else
      HAS_WRITE_OUTPUT=$(settings put global "$2" "$4" 2>&1)
    fi
  else
    if [ "$1" = system ]; then
      HAS_WRITE_OUTPUT=$(settings --user 0 delete system "$2" 2>&1)
    else
      HAS_WRITE_OUTPUT=$(settings delete global "$2" 2>&1)
    fi
  fi
  HAS_WRITE_RC=$?
  [ "$HAS_WRITE_RC" = 0 ] || has_error "写入 $1.$2 失败：$HAS_WRITE_OUTPUT"
}

has_write_pair() {
  HAS_PAIR_RC=0
  has_write_setting system long_press_power_key "$1" "$2" || HAS_PAIR_RC=1
  has_write_setting global power_button_long_press "$3" "$4" || HAS_PAIR_RC=1
  return "$HAS_PAIR_RC"
}

has_pair_matches() {
  [ "$HAS_SYSTEM_PRESENT" = "$1" ] && [ "$HAS_SYSTEM_VALUE" = "$2" ] &&
    [ "$HAS_GLOBAL_PRESENT" = "$3" ] && [ "$HAS_GLOBAL_VALUE" = "$4" ]
}

has_save_original() {
  [ ! -e "$HAS_STATE_DIR/original" ] || return 0
  # Write directly: command substitution would strip trailing empty values.
  if (umask 077; printf '%s\n' 'HAS_ORIGINAL_V1' "$HAS_SYSTEM_PRESENT" \
    "$HAS_SYSTEM_VALUE" "$HAS_GLOBAL_PRESENT" "$HAS_GLOBAL_VALUE" \
    > "$HAS_STATE_DIR/original.tmp.$$") &&
    mv -f "$HAS_STATE_DIR/original.tmp.$$" "$HAS_STATE_DIR/original"; then
    return 0
  fi
  rm -f "$HAS_STATE_DIR/original.tmp.$$"
  has_error '无法备份原始设置，已取消修改。'
}

has_load_original() {
  [ -f "$HAS_STATE_DIR/original" ] || {
    has_error '原始设置备份不存在。'
    return 1
  }
  {
    IFS= read -r HAS_ORIGINAL_FORMAT &&
      IFS= read -r HAS_ORIGINAL_SP && IFS= read -r HAS_ORIGINAL_SV &&
      IFS= read -r HAS_ORIGINAL_GP && IFS= read -r HAS_ORIGINAL_GV &&
      ! IFS= read -r _has_extra
  } < "$HAS_STATE_DIR/original" || {
    has_error '原始设置备份损坏，未修改系统。'
    return 1
  }
  [ "$HAS_ORIGINAL_FORMAT" = HAS_ORIGINAL_V1 ] || {
    has_error '无法识别原始设置备份格式。'
    return 1
  }
  case "$HAS_ORIGINAL_SP:$HAS_ORIGINAL_GP" in
    0:0|0:1|1:0|1:1) ;;
    *) has_error '原始设置备份中的存在标记无效。'; return 1 ;;
  esac
  if { [ "$HAS_ORIGINAL_SP" = 0 ] && [ -n "$HAS_ORIGINAL_SV" ]; } ||
    { [ "$HAS_ORIGINAL_GP" = 0 ] && [ -n "$HAS_ORIGINAL_GV" ]; }; then
    has_error '原始设置备份中的空值标记无效。'
    return 1
  fi
}

# Caller holds the operation lock. Settings + saved intent are one transaction.
has_apply() {
  HAS_ERROR=
  HAS_TARGET=$1
  # Shared return value consumed by service.sh after this function returns.
  # shellcheck disable=SC2034
  HAS_APPLY_CHANGED=0
  case "$HAS_TARGET" in assistant|xiaoai) ;; *) has_error '未知目标模式。'; return 1 ;; esac
  has_read_settings || return 1
  HAS_BEFORE_SP=$HAS_SYSTEM_PRESENT
  HAS_BEFORE_SV=$HAS_SYSTEM_VALUE
  HAS_BEFORE_GP=$HAS_GLOBAL_PRESENT
  HAS_BEFORE_GV=$HAS_GLOBAL_VALUE
  has_save_original || return 1
  # Validate an existing backup before relying on it for a future uninstall.
  has_load_original || return 1
  HAS_APPLY_OK=1
  if [ "$HAS_CURRENT" != "$HAS_TARGET" ]; then
    # shellcheck disable=SC2034
    HAS_APPLY_CHANGED=1
    if [ "$HAS_TARGET" = assistant ]; then
      has_write_pair 1 launch_google_search 1 0 || HAS_APPLY_OK=0
    else
      has_write_pair 0 '' 1 1 || HAS_APPLY_OK=0
    fi
    has_read_settings || HAS_APPLY_OK=0
    [ "$HAS_CURRENT" = "$HAS_TARGET" ] || HAS_APPLY_OK=0
  fi
  if [ "$HAS_APPLY_OK" = 1 ]; then
    has_atomic_write "$HAS_STATE_DIR/mode" "$HAS_TARGET" || HAS_APPLY_OK=0
  fi
  [ "$HAS_APPLY_OK" = 0 ] || return 0

  HAS_FAILURE=${HAS_ERROR:-设置读回验证不一致，可能被 HyperOS 重写。}
  if has_write_pair "$HAS_BEFORE_SP" "$HAS_BEFORE_SV" "$HAS_BEFORE_GP" "$HAS_BEFORE_GV" &&
    has_read_settings &&
    has_pair_matches "$HAS_BEFORE_SP" "$HAS_BEFORE_SV" "$HAS_BEFORE_GP" "$HAS_BEFORE_GV"; then
    has_error "$HAS_FAILURE 已回滚到操作前的设置，保存模式未改变。"
  else
    has_error "$HAS_FAILURE 回滚未能验证；请检查 status 输出并重新设置模式。"
  fi
}

has_restore_original() {
  has_load_original && has_read_settings || return 1
  if has_pair_matches "$HAS_ORIGINAL_SP" "$HAS_ORIGINAL_SV" "$HAS_ORIGINAL_GP" "$HAS_ORIGINAL_GV"; then
    return 0
  fi
  if has_write_pair "$HAS_ORIGINAL_SP" "$HAS_ORIGINAL_SV" "$HAS_ORIGINAL_GP" "$HAS_ORIGINAL_GV" &&
    has_read_settings &&
    has_pair_matches "$HAS_ORIGINAL_SP" "$HAS_ORIGINAL_SV" "$HAS_ORIGINAL_GP" "$HAS_ORIGINAL_GV"; then
    return 0
  fi
  has_error '恢复原始设置未通过读回验证；备份已保留。'
}

has_log() {
  # Called while holding the operation lock; keep at most two small log files.
  if [ -f "$HAS_STATE_DIR/service.log" ] &&
    [ "$(wc -c < "$HAS_STATE_DIR/service.log")" -ge 32768 ]; then
    mv -f "$HAS_STATE_DIR/service.log" "$HAS_STATE_DIR/service.log.1"
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HAS_STATE_DIR/service.log"
}

has_cleanup_restore() {
  # Keep the backup until hook removal succeeds; never recursively remove /data.
  rm -f "$HAS_RESTORE_HOOK" || return 1
  rm -f "$HAS_STATE_DIR/mode" "$HAS_STATE_DIR/guard" \
    "$HAS_STATE_DIR/common.sh" "$HAS_STATE_DIR/restore.sh" \
    "$HAS_STATE_DIR/uninstalling" "$HAS_STATE_DIR/original"
}
