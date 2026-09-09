#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
# shellcheck source=module/common.sh
. "$MODDIR/common.sh"
has_root && has_prepare && has_active || exit 1
mkdir "$HAS_RUN_DIR/service" 2>/dev/null || exit 0
HAS_SERVICE_OWNED=1
has_release_service() {
  if [ "$HAS_SERVICE_OWNED" = 1 ]; then
    rmdir "$HAS_RUN_DIR/service" 2>/dev/null
    HAS_SERVICE_OWNED=0
  fi
}
trap 'has_unlock; has_release_service' 0
trap 'exit 130' 2
trap 'exit 143' 15

has_service_wait() {
  HAS_REMAINING=$1
  while [ "$HAS_REMAINING" -gt 0 ]; do
    has_active || return 1
    if [ "$HAS_REMAINING" -gt 5 ]; then HAS_STEP=5; else HAS_STEP=$HAS_REMAINING; fi
    sleep "$HAS_STEP"
    HAS_REMAINING=$((HAS_REMAINING - HAS_STEP))
  done
  has_active
}

has_reconcile() {
  HAS_RECONCILE_RC=1
  has_lock || return 1
  if ! has_active; then has_unlock; return 1; fi
  HAS_ERROR=
  if has_load_mode && has_apply "$HAS_MODE"; then
    if [ "$HAS_SERVICE_LAST" != "$HAS_MODE" ] || [ "$HAS_APPLY_CHANGED" = 1 ]; then
      has_log "校正完成：$(has_mode_label "$HAS_MODE")"
    fi
    HAS_SERVICE_LAST=$HAS_MODE
    HAS_RECONCILE_RC=0
  else
    has_log "校正失败：$HAS_ERROR"
    HAS_RECONCILE_RC=1
  fi
  has_unlock
  return "$HAS_RECONCILE_RC"
}

has_guard_interval() {
  has_lock || { HAS_RECONCILE_RC=1; return 1; }
  if has_active && has_load_guard; then
    if [ "$HAS_GUARD" != off ]; then
      HAS_INTERVAL=$HAS_GUARD
      has_unlock
      return 0
    fi
  elif has_active; then
    has_log "守护配置无效：$HAS_ERROR"
    HAS_RECONCILE_RC=1
  fi
  # Serialize the exit decision with `guard on`: do not leave an enabled guard
  # without a worker if it is enabled at the end of the boot-check phase.
  has_release_service
  has_unlock
  return 1
}

# Do not touch Settings in post-fs-data or block Android's boot sequence.
HAS_BOOT_WAIT=0
until [ "$(getprop sys.boot_completed)" = 1 ]; do
  if [ "$HAS_BOOT_WAIT" -ge 180 ]; then
    if has_lock; then
      has_log '等待开机完成超时，未修改设置；系统启动后可运行 reapply。'
      has_unlock
    fi
    exit 1
  fi
  has_service_wait 5 || exit 0
  HAS_BOOT_WAIT=$((HAS_BOOT_WAIT + 5))
done

# Rechecks occur at approximately 0, 10, 30, 60, 120 s after boot completion.
# Read saved intent afresh inside every lock so Action wins over an old choice.
HAS_SERVICE_LAST=
HAS_RECONCILE_RC=1
for HAS_DELAY in 0 10 20 30 60; do
  has_service_wait "$HAS_DELAY" || exit 0
  has_reconcile
done

# Default: no resident loop. Opt-in guard does not rewrite matching settings.
while has_active; do
  has_guard_interval || exit "$HAS_RECONCILE_RC"
  sleep "$HAS_INTERVAL"
  has_active || exit 0
  has_guard_interval || exit "$HAS_RECONCILE_RC"
  has_reconcile
done
exit 0
