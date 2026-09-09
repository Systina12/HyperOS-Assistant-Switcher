#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
# shellcheck source=module/common.sh
. "$MODDIR/common.sh"

has_usage() {
  cat <<'EOF'
HyperOS 助理切换
  control.sh status                  查看实际设置、保存模式与守护状态
  control.sh toggle                  在两个入口之间切换（Action 使用）
  control.sh set assistant|xiaoai     明确设置并保存模式
  control.sh reapply                 重新应用保存的模式
  control.sh guard on|off|60..3600    低频守护，on = 每 60 秒检查
  control.sh restore                 恢复首次接管前的设置并暂停模块
EOF
}

has_status() {
  has_read_settings || return 1
  printf '当前入口：%s\n' "$(has_mode_label "$HAS_CURRENT")"
  if has_load_mode; then
    printf '保存模式：%s\n' "$(has_mode_label "$HAS_MODE")"
    if [ "$HAS_CURRENT" != "$HAS_MODE" ]; then
      printf '%s\n' '提示：实际设置与保存模式不一致。'
    fi
  else
    printf '保存模式：[错误] %s\n' "$HAS_ERROR"
  fi
  if [ "$HAS_SYSTEM_PRESENT" = 1 ]; then
    printf 'system[user 0].long_press_power_key = %s\n' "$HAS_SYSTEM_VALUE"
  else
    printf '%s\n' 'system[user 0].long_press_power_key = <不存在>'
  fi
  if [ "$HAS_GLOBAL_PRESENT" = 1 ]; then
    printf 'global.power_button_long_press = %s\n' "$HAS_GLOBAL_VALUE"
  else
    printf '%s\n' 'global.power_button_long_press = <不存在>'
  fi
  if has_load_guard; then
    if [ "$HAS_GUARD" = off ]; then
      printf '%s\n' '守护配置：关闭（只做开机有限次校正）'
    else
      printf '守护配置：每 %s 秒检查\n' "$HAS_GUARD"
    fi
  else
    printf '守护配置：[错误] %s\n' "$HAS_ERROR"
  fi
  if [ -d "$HAS_RUN_DIR/service" ]; then
    printf '%s\n' '后台任务：运行中（或上次被强制终止，重启可清除）'
  else
    printf '%s\n' '后台任务：未运行'
  fi
  if ! has_active; then
    printf '%s\n' '模块已禁用、待移除或正在恢复；不会继续校正设置。'
  fi
  printf '%s\n' '以上是设置状态；请长按电源键确认实际入口。'
}

HAS_COMMAND=${1:-status}
case "$HAS_COMMAND" in help|-h|--help) has_usage; exit 0 ;; esac
has_root || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
if [ "$HAS_COMMAND" = status ]; then
  has_status || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
  exit 0
fi

case "$HAS_COMMAND" in
  toggle|reapply|restore) [ "$#" -le 1 ] || { has_usage; exit 2; } ;;
  set)
    [ "$#" = 2 ] || { has_usage; exit 2; }
    case "$2" in assistant|xiaoai) ;; *) has_usage; exit 2 ;; esac
    ;;
  guard)
    [ "$#" = 2 ] || { has_usage; exit 2; }
    case "$2" in
      on) HAS_NEW_GUARD=60 ;;
      off) HAS_NEW_GUARD=off ;;
      ''|*[!0-9]*|0*|?????*) has_usage; exit 2 ;;
      *)
        [ "$2" -ge 60 ] && [ "$2" -le 3600 ] || { has_usage; exit 2; }
        HAS_NEW_GUARD=$2
        ;;
    esac
    ;;
  *) has_usage; exit 2 ;;
esac

# SukiSU bounds Action execution at 10 s; leave time to report lock contention.
has_lock 3 || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
trap 'has_unlock' 0
trap 'exit 130' 2
trap 'exit 143' 15
if ! has_active; then
  printf '%s\n' '[失败] 模块已禁用、待移除或正在恢复；请先在管理器中启用并重启。' >&2
  exit 1
fi

case "$HAS_COMMAND" in
  guard)
    has_atomic_write "$HAS_STATE_DIR/guard" "$HAS_NEW_GUARD" || {
      printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1;
    }
    has_unlock
    if [ "$HAS_NEW_GUARD" = off ]; then
      printf '%s\n' '低频守护已关闭；正在等待的守护会在下次检查时退出。开机校正仍保留。'
    else
      sh "$MODDIR/service.sh" >/dev/null 2>&1 &
      printf '低频守护已配置为每 %s 秒检查，已请求启动后台任务。\n' "$HAS_NEW_GUARD"
    fi
    exit 0
    ;;
  restore)
    if has_restore_original; then
      if touch "$MODDIR/disable"; then
        printf '%s\n' '已恢复首次接管前的设置，并禁用模块。可在管理器中卸载，或重新启用后重启。'
        has_log '手动恢复原始设置并禁用模块。'
        exit 0
      fi
      HAS_ERROR='原始设置已恢复，但无法禁用模块；请立即在管理器中禁用。'
    fi
    printf '[失败] %s\n' "$HAS_ERROR" >&2
    exit 1
    ;;
esac

has_read_settings || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
printf '当前入口：%s\n' "$(has_mode_label "$HAS_CURRENT")"
case "$HAS_COMMAND" in
  set) HAS_NEXT=$2 ;;
  reapply)
    has_load_mode || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
    HAS_NEXT=$HAS_MODE
    ;;
  toggle)
    case "$HAS_CURRENT" in
      assistant) HAS_NEXT=xiaoai ;;
      xiaoai) HAS_NEXT=assistant ;;
      *)
        has_load_mode || { printf '[失败] %s\n' "$HAS_ERROR" >&2; exit 1; }
        HAS_NEXT=$HAS_MODE
        printf '%s\n' '当前组合不是标准模式，本次恢复已保存的选择。'
        ;;
    esac
    ;;
esac
if has_apply "$HAS_NEXT"; then
  printf '切换成功：%s（两项设置已读回验证）\n' "$(has_mode_label "$HAS_NEXT")"
  has_log "已切换：$(has_mode_label "$HAS_NEXT")"
  if [ "$HAS_NEXT" = assistant ]; then
    printf '%s\n' '请在系统“默认应用 / 数字助理应用”中选择助理，然后长按电源键测试。'
  fi
  exit 0
fi
printf '[失败] %s\n' "$HAS_ERROR" >&2
has_log "切换失败：$HAS_ERROR"
exit 1
