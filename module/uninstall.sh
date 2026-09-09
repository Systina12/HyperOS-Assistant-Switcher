#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
# shellcheck source=module/common.sh
. "$MODDIR/common.sh"
has_root && has_lock 10 || exit 1
trap 'has_unlock' 0
trap 'exit 130' 2
trap 'exit 143' 15
touch "$HAS_STATE_DIR/uninstalling" || exit 1
# Stop an already-running service even before the manager deletes this folder.
touch "$MODDIR/disable" || exit 1

if [ ! -f "$HAS_STATE_DIR/original" ]; then
  has_cleanup_restore
  exit $?
fi
if [ "$(getprop sys.boot_completed)" = 1 ] && has_restore_original; then
  has_log '卸载：已恢复首次接管前的两项设置。'
  has_cleanup_restore
  exit $?
fi

# Magisk may uninstall before SettingsProvider starts. A module-local script
# would be deleted, so persist a small restore job in the manager's service.d.
if ! cp -f "$MODDIR/common.sh" "$HAS_STATE_DIR/common.sh" ||
  ! cp -f "$MODDIR/restore.sh" "$HAS_STATE_DIR/restore.sh" ||
  ! mkdir -p "${HAS_RESTORE_HOOK%/*}"; then
  has_log '无法创建延后恢复任务；原始备份已保留，请手动恢复。'
  exit 1
fi
chmod 600 "$HAS_STATE_DIR/common.sh"
chmod 700 "$HAS_STATE_DIR/restore.sh"
# Production paths are fixed. The environment overrides exist for host tests.
if ! cat > "$HAS_RESTORE_HOOK.tmp.$$" <<'EOF'
#!/system/bin/sh
HAS_STATE_DIR=${HAS_STATE_DIR:-/data/adb/hyperos_assistant_switcher}
[ -f "$HAS_STATE_DIR/uninstalling" ] || exit 0
sh "$HAS_STATE_DIR/restore.sh" >/dev/null 2>&1 &
EOF
then
  has_log '无法写入延后恢复入口；原始备份已保留。'
  exit 1
fi
chmod 700 "$HAS_RESTORE_HOOK.tmp.$$" &&
  mv -f "$HAS_RESTORE_HOOK.tmp.$$" "$HAS_RESTORE_HOOK" || exit 1
has_log '已安排延后恢复：等待系统启动；恢复成功后自动删除恢复任务和备份。'
has_unlock
# Handle immediate manager uninstalls too; the hook covers process termination.
sh "$HAS_STATE_DIR/restore.sh" >/dev/null 2>&1 &
exit 0
