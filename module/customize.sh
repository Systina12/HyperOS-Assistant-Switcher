#!/system/bin/sh
# Sourced by the manager; never exit from this installer customization script.
[ "$BOOTMODE" = true ] || abort '请在 Magisk / SukiSU 管理器中安装，不支持 Recovery 安装。'
[ "${API:-0}" -ge 31 ] || abort '需要 Android 12 或更新版本的 HyperOS。'

ui_print 'HyperOS 助理切换'
ui_print '恢复 Android 默认数字助理机制，不指定或安装助理应用。'
ui_print '首次安装默认使用系统数字助理；升级保留已保存模式。'
ui_print '默认只在开机后校正，可通过 control.sh 开启低频守护。'
ui_print '请先在系统默认应用中选好数字助理，安装后重启。'
if [ "$(getprop ro.mi.os.version.name)" = '' ] && [ "$(getprop ro.miui.ui.version.name)" = '' ]; then
  ui_print '提示：未识别到小米系统标记；设置键是否生效取决于 ROM。'
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
for HAS_SCRIPT in action.sh control.sh service.sh uninstall.sh restore.sh; do
  set_perm "$MODPATH/$HAS_SCRIPT" 0 0 0755
done

MODDIR=$MODPATH
# shellcheck source=module/common.sh
. "$MODPATH/common.sh"
# Cancel an older pending uninstall under the same lock as its restore worker.
has_lock 10 || abort "$HAS_ERROR"
if ! rm -f "$HAS_RESTORE_HOOK" "$HAS_STATE_DIR/uninstalling" \
  "$HAS_STATE_DIR/restore.sh" "$HAS_STATE_DIR/common.sh"; then
  has_unlock
  abort '无法取消先前的卸载恢复任务。'
fi
has_unlock
