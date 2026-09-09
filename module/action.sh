#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
printf '%s\n' 'HyperOS 助理切换' '--------------------------'
exec sh "$MODDIR/control.sh" toggle
