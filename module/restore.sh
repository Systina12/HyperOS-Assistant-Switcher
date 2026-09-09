#!/system/bin/sh
# Also copied to the private state directory so it survives module removal.
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
# shellcheck source=module/common.sh
. "$MODDIR/common.sh"
has_root && has_prepare || exit 1
HAS_DEFERRED_WAIT=0
until [ "$(getprop sys.boot_completed)" = 1 ]; do
  [ -f "$HAS_STATE_DIR/uninstalling" ] || exit 0
  [ "$HAS_DEFERRED_WAIT" -lt 180 ] || exit 1
  sleep 5
  HAS_DEFERRED_WAIT=$((HAS_DEFERRED_WAIT + 5))
done

HAS_RESTORE_ATTEMPT=0
while [ "$HAS_RESTORE_ATTEMPT" -lt 6 ]; do
  has_lock 10 || exit 1
  trap 'has_unlock' 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  # Reinstall may have cancelled this job while we were waiting for the lock.
  if [ ! -f "$HAS_STATE_DIR/uninstalling" ]; then exit 0; fi
  if has_restore_original; then
    has_log '卸载：已恢复首次接管前的两项设置。'
    has_cleanup_restore || exit 1
    exit 0
  fi
  has_log "卸载恢复等待重试：$HAS_ERROR"
  has_unlock
  HAS_RESTORE_ATTEMPT=$((HAS_RESTORE_ATTEMPT + 1))
  [ "$HAS_RESTORE_ATTEMPT" -ge 6 ] || sleep 10
done
# Keep the hook and backup for the next boot if Settings is still unavailable.
exit 1
