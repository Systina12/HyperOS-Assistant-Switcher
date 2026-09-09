"""Run the real module scripts with a private, fault-injectable SettingsProvider.

No Android device, root privileges, external packages, or real settings are used.
HAS_TEST_SHELL can select dash, mksh, bash, or 'busybox ash' on Linux/macOS.
On Windows, Git for Windows supplies dash and the standard POSIX utilities.
"""

from __future__ import annotations

import importlib.util
import os
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def shell_path(path: Path) -> str:
    result = path.resolve().as_posix()
    if os.name == "nt" and len(result) > 1 and result[1] == ":":
        return f"/{result[0].lower()}{result[2:]}"
    return result


def find_shell() -> list[str]:
    if os.environ.get("HAS_TEST_SHELL"):
        command = shlex.split(os.environ["HAS_TEST_SHELL"])
        command[0] = shutil.which(command[0]) or command[0]
        return command
    if os.name == "nt":
        git = shutil.which("git")
        if git:
            candidate = Path(git).resolve().parents[1] / "usr/bin/dash.exe"
            if candidate.is_file():
                return [str(candidate)]
        raise RuntimeError("Install Git for Windows to run shell integration tests")
    return [shutil.which("dash") or shutil.which("sh") or "/bin/sh"]


SHELL = find_shell()

SETTINGS_MOCK = r'''#!/bin/sh
user=global
if [ "$1" = --user ]; then
  user=$2
  shift 2
fi
verb=$1
table=$2
key=${3:-}
case "$user:$table" in 0:system|global:global) ;; *) echo 'Bad user or table' >&2; exit 20 ;; esac
if [ "$verb" != list ]; then
  case "$table:$key" in system:long_press_power_key|global:power_button_long_press) ;;
    *) echo 'Unexpected key' >&2; exit 21 ;;
  esac
fi
printf '%s|%s|%s|%s|%s\n' "$user" "$verb" "$table" "$key" "${4:-}" >> "$MOCK_DB/calls"
case "$verb" in
  get|list)
    if [ -f "$MOCK_DB/read-failure" ]; then echo 'SettingsProvider unavailable' >&2; exit 1; fi
    if [ -f "$MOCK_DB/read-error-zero" ]; then echo 'java.lang.SecurityException: uid=0 denied'; exit 0; fi
    if [ "$verb" = get ]; then
      if [ -f "$MOCK_DB/$table" ]; then cat "$MOCK_DB/$table"; else printf 'null\n'; fi
      exit 0
    fi
    if [ "$table" = system ]; then key=long_press_power_key; else key=power_button_long_press; fi
    printf '%s\n' 'unrelated_key=untouched'
    [ ! -f "$MOCK_DB/list-extra" ] || cat "$MOCK_DB/list-extra"
    [ ! -f "$MOCK_DB/$table" ] || printf '%s=%s\n' "$key" "$(cat "$MOCK_DB/$table")"
    ;;
  put|delete)
    if [ -f "$MOCK_DB/fail-all-writes" ]; then echo 'Permission denied' >&2; exit 1; fi
    if [ -f "$MOCK_DB/fail-write-once" ] && [ "$(cat "$MOCK_DB/fail-write-once")" = "$table" ]; then
      rm -f "$MOCK_DB/fail-write-once"
      echo 'Injected write failure' >&2
      exit 1
    fi
    if [ -f "$MOCK_DB/ignore-write-once" ] && [ "$(cat "$MOCK_DB/ignore-write-once")" = "$table" ]; then
      rm -f "$MOCK_DB/ignore-write-once"
      exit 0
    fi
    if [ -f "$MOCK_DB/slow-write" ]; then /bin/sleep 0.15; fi
    if [ "$verb" = put ]; then printf '%s\n' "$4" > "$MOCK_DB/$table"; else rm -f "$MOCK_DB/$table"; fi
    ;;
  *) echo 'Unexpected command' >&2; exit 22 ;;
esac
exit 0
'''

SLEEP_MOCK = r'''#!/bin/sh
if [ "${MOCK_REAL_SLEEP:-0}" = 1 ]; then exec /bin/sleep "$@"; fi
printf '%s\n' "$1" >> "$MOCK_DB/sleeps"
elapsed=0
[ ! -f "$MOCK_DB/elapsed" ] || elapsed=$(cat "$MOCK_DB/elapsed")
elapsed=$((elapsed + $1))
printf '%s\n' "$elapsed" > "$MOCK_DB/elapsed"
if [ -f "$MOCK_DB/boot-at" ] && [ "$elapsed" -ge "$(cat "$MOCK_DB/boot-at")" ]; then
  printf '1\n' > "$MOCK_DB/boot"
  rm -f "$MOCK_DB/boot-at"
fi
if [ -f "$MOCK_DB/rewrite-at" ] && [ "$elapsed" -ge "$(cat "$MOCK_DB/rewrite-at")" ]; then
  rm -f "$MOCK_DB/system" "$MOCK_DB/rewrite-at"
  printf '1\n' > "$MOCK_DB/global"
fi
if [ -f "$MOCK_DB/action-at" ] && [ "$elapsed" -ge "$(cat "$MOCK_DB/action-at")" ]; then
  rm -f "$MOCK_DB/action-at"
  sh "$MOCK_MODULE/control.sh" set xiaoai > "$MOCK_DB/late-action-output" 2>&1 || exit 30
fi
if [ -f "$MOCK_DB/disable-at" ] && [ "$elapsed" -ge "$(cat "$MOCK_DB/disable-at")" ]; then
  touch "$MOCK_MODULE/disable"
fi
if [ -f "$MOCK_DB/guard-off-at" ] && [ "$elapsed" -ge "$(cat "$MOCK_DB/guard-off-at")" ]; then
  printf 'off\n' > "$HAS_STATE_DIR/guard"
fi
'''

SH_MOCK = r'''#!/bin/sh
case "${1:-}" in
  */service.sh|*/restore.sh)
    printf '%s\n' "$1" >> "$MOCK_DB/background"
    [ "${MOCK_SUPPRESS_BACKGROUND:-1}" != 1 ] || exit 0
    ;;
esac
if [ -n "$HAS_REAL_SHELL_ARG" ]; then
  exec "$HAS_REAL_SHELL" "$HAS_REAL_SHELL_ARG" "$@"
fi
exec "$HAS_REAL_SHELL" "$@"
'''


class ModuleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="has-tests-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.module = self.base / "module with spaces"
        shutil.copytree(ROOT / "module", self.module)
        self.db = self.base / "settings"
        self.state = self.base / "state"
        self.run_dir = self.base / "run"
        self.hook = self.base / "service.d/restore.sh"
        self.bin = self.base / "bin"
        for folder in (self.db, self.state, self.bin):
            folder.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            HAS_STATE_DIR=shell_path(self.state),
            HAS_RUN_DIR=shell_path(self.run_dir),
            HAS_RESTORE_HOOK=shell_path(self.hook),
            HAS_REAL_SHELL=shell_path(Path(SHELL[0])),
            HAS_REAL_SHELL_ARG=SHELL[1] if len(SHELL) > 1 else "",
            MOCK_MODULE=shell_path(self.module),
            MOCK_DB=shell_path(self.db),
            MOCK_SUPPRESS_BACKGROUND="1",
            # BusyBox standalone mode bypasses PATH mocks; use ordinary ash.
            ASH_STANDALONE="0",
            LC_ALL="C.UTF-8",
        )
        paths = [str(self.bin)]
        if os.name == "nt":
            paths.append(str(Path(SHELL[0]).parent))
        self.env["PATH"] = os.pathsep.join(paths + [self.env.get("PATH", "")])
        self.write(self.db / "global", "1\n")
        self.write(self.db / "boot", "1\n")
        self.mock("settings", SETTINGS_MOCK)
        self.mock("sleep", SLEEP_MOCK)
        self.mock("sh", SH_MOCK)
        self.mock("id", '#!/bin/sh\nprintf "%s\\n" "${MOCK_UID:-0}"\n')
        self.mock("getprop", r'''#!/bin/sh
case "$1" in
  sys.boot_completed) cat "$MOCK_DB/boot" ;;
  ro.mi.os.version.name) printf 'OS3.0\n' ;;
  *) printf '\n' ;;
esac
''')
        self.mock("mv", r'''#!/bin/sh
last=
for arg do last=$arg; done
if [ "$last" = "$HAS_STATE_DIR/mode" ] && [ -f "$MOCK_DB/fail-save-mode" ]; then
  rm -f "$MOCK_DB/fail-save-mode"
  exit 1
fi
if [ "$last" = "$HAS_STATE_DIR/original" ] && [ -f "$MOCK_DB/fail-save-original" ]; then exit 1; fi
exec /bin/mv "$@"
''')

    @staticmethod
    def write(path: Path, value: str) -> None:
        path.write_text(value, encoding="utf-8", newline="\n")

    def mock(self, name: str, script: str) -> None:
        target = self.bin / name
        self.write(target, script)
        target.chmod(0o755)

    def invoke(self, script: str = "control.sh", *args: str, ok: bool = True) -> subprocess.CompletedProcess:
        path = Path(script) if Path(script).is_absolute() else self.module / script
        result = subprocess.run(
            [*SHELL, shell_path(path), *args],
            cwd=ROOT,
            env=self.env,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=30,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def value(self, table: str) -> str | None:
        path = self.db / table
        return path.read_text(encoding="utf-8").removesuffix("\n") if path.exists() else None

    def assert_pair(self, system: str | None, global_value: str | None) -> None:
        self.assertEqual((self.value("system"), self.value("global")), (system, global_value))

    def calls(self, writes_only: bool = False) -> list[str]:
        path = self.db / "calls"
        lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
        return [line for line in lines if not writes_only or line.split("|")[1] in ("put", "delete")]

    def clear_calls(self) -> None:
        self.write(self.db / "calls", "")

    def test_status_is_read_only_and_reports_missing_keys(self) -> None:
        result = self.invoke("control.sh", "status")
        self.assertIn("超级小爱", result.stdout)
        self.assertIn("<不存在>", result.stdout)
        self.assertEqual(self.calls(writes_only=True), [])
        self.assertFalse((self.state / "original").exists())

    def test_action_toggles_both_ways_and_reports_verified_result(self) -> None:
        first = self.invoke("action.sh")
        self.assert_pair("launch_google_search", "0")
        self.assertIn("切换成功：系统默认数字助理", first.stdout)
        self.assertIn("当前入口：超级小爱", first.stdout)
        second = self.invoke("action.sh")
        self.assert_pair(None, "1")
        self.assertIn("切换成功：超级小爱", second.stdout)
        self.assertEqual((self.state / "mode").read_text().strip(), "xiaoai")
        self.assertEqual(self.calls(True), [
            "0|put|system|long_press_power_key|launch_google_search",
            "global|put|global|power_button_long_press|0",
            "0|delete|system|long_press_power_key|",
            "global|put|global|power_button_long_press|1",
        ])

    def test_custom_combination_recovers_saved_choice(self) -> None:
        self.write(self.db / "system", "custom_power_action\n")
        self.write(self.state / "mode", "xiaoai\n")
        result = self.invoke("action.sh")
        self.assertIn("本次恢复已保存的选择", result.stdout)
        self.assert_pair(None, "1")

    def test_manager_action_invocation_and_chinese_output(self) -> None:
        cases = (
            ("Magisk", "./action.sh", {"MAGISK_VER_CODE": "30400"}),
            ("SukiSU", shell_path(self.module / "action.sh"), {"KSU": "true", "KSU_SUKISU": "true"}),
            ("terminal", "action.sh", {}),
        )
        for manager, entry, flags in cases:
            with self.subTest(manager=manager):
                (self.db / "system").unlink(missing_ok=True)
                self.write(self.db / "global", "1\n")
                result = subprocess.run(
                    [*SHELL, entry], cwd=self.module, env={**self.env, **flags},
                    capture_output=True, text=True, encoding="utf-8", timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_pair("launch_google_search", "0")
                self.assertIn("HyperOS 助理切换", result.stdout)
                self.assertIn("当前入口：超级小爱", result.stdout)
                self.assertIn("切换成功：系统默认数字助理", result.stdout)
                self.assertNotIn("long_press_power_key", result.stdout)
                self.assertLessEqual(len(result.stdout.splitlines()), 5)

    def test_action_lock_wait_leaves_time_for_sukisu_result(self) -> None:
        (self.run_dir / "operation").mkdir(parents=True)
        result = self.invoke("action.sh", ok=False)
        self.assertIn("[失败]", result.stderr)
        self.assertEqual((self.db / "elapsed").read_text().strip(), "3")
        self.assertEqual(self.calls(True), [])

    def test_action_failure_is_propagated_without_success_message(self) -> None:
        self.write(self.db / "fail-write-once", "global\n")
        result = self.invoke("action.sh", ok=False)
        self.assert_pair(None, "1")
        self.assertNotIn("切换成功", result.stdout)
        self.assertIn("已回滚", result.stderr)

    def test_unrelated_multiline_settings_do_not_block_action(self) -> None:
        self.write(self.db / "list-extra", "unrelated_multiline=first line\nsecond line\n\n")
        self.invoke("action.sh")
        self.assert_pair("launch_google_search", "0")

    def test_multiline_target_values_are_rejected_before_backup(self) -> None:
        for value in ("custom\nsecond line\n", "custom\n\n"):
            with self.subTest(value=value):
                self.write(self.db / "system", value)
                self.invoke("action.sh", ok=False)
                self.assertEqual(self.calls(True), [])
                self.assertFalse((self.state / "original").exists())

    def test_reapply_uses_saved_intent_after_system_rewrite(self) -> None:
        self.invoke("control.sh", "set", "assistant")
        (self.db / "system").unlink()
        self.write(self.db / "global", "1\n")
        self.invoke("control.sh", "reapply")
        self.assert_pair("launch_google_search", "0")

    def test_repeated_set_is_idempotent(self) -> None:
        self.invoke("control.sh", "set", "assistant")
        original = (self.state / "original").read_bytes()
        self.clear_calls()
        self.invoke("control.sh", "set", "assistant")
        self.assertEqual(self.calls(True), [])
        self.assertEqual((self.state / "original").read_bytes(), original)

    def test_second_write_failure_rolls_back_and_keeps_saved_mode(self) -> None:
        self.write(self.state / "mode", "xiaoai\n")
        self.write(self.db / "fail-write-once", "global\n")
        result = self.invoke("control.sh", "set", "assistant", ok=False)
        self.assert_pair(None, "1")
        self.assertIn("已回滚", result.stderr)
        self.assertEqual((self.state / "mode").read_text().strip(), "xiaoai")

    def test_zero_exit_without_writing_is_caught_by_readback(self) -> None:
        self.write(self.db / "ignore-write-once", "global\n")
        result = self.invoke("control.sh", "set", "assistant", ok=False)
        self.assert_pair(None, "1")
        self.assertIn("已回滚", result.stderr)

    def test_failed_rollback_is_reported(self) -> None:
        self.write(self.db / "fail-all-writes", "1\n")
        result = self.invoke("control.sh", "set", "assistant", ok=False)
        self.assertIn("回滚未能验证", result.stderr)
        self.assertFalse((self.state / "mode").exists())

    def test_saved_intent_failure_rolls_back_system_settings(self) -> None:
        self.write(self.state / "mode", "xiaoai\n")
        self.write(self.db / "fail-save-mode", "1\n")
        result = self.invoke("control.sh", "set", "assistant", ok=False)
        self.assert_pair(None, "1")
        self.assertIn("已回滚", result.stderr)
        self.assertEqual((self.state / "mode").read_text().strip(), "xiaoai")

    def test_backup_failure_prevents_any_setting_write(self) -> None:
        self.write(self.db / "fail-save-original", "1\n")
        self.invoke("control.sh", "set", "assistant", ok=False)
        self.assertEqual(self.calls(True), [])

    def test_read_errors_including_success_exit_prevent_writes(self) -> None:
        for name in ("read-failure", "read-error-zero"):
            with self.subTest(name=name):
                self.write(self.db / name, "1\n")
                self.invoke("control.sh", "set", "assistant", ok=False)
                self.assertEqual(self.calls(True), [])
                (self.db / name).unlink()

    def test_corrupt_backup_prevents_writes(self) -> None:
        self.write(self.state / "original", "not-a-valid-backup\n")
        self.invoke("control.sh", "set", "assistant", ok=False)
        self.assertEqual(self.calls(True), [])

    def test_data_files_cannot_execute_shell_commands(self) -> None:
        marker = shell_path(self.base / "injected")
        self.write(self.state / "mode", f"$(touch '{marker}')\n")
        self.invoke("control.sh", "reapply", ok=False)
        self.assertFalse((self.base / "injected").exists())
        self.assertEqual(self.calls(True), [])
        self.invoke("control.sh", "set", "assistant")
        self.assertEqual((self.state / "mode").read_text().strip(), "assistant")

    def test_guard_validation_and_background_start(self) -> None:
        for value in ("0", "59", "3601", "060", "-60", "1;id", "", "on extra"):
            with self.subTest(value=value):
                self.invoke("control.sh", "guard", value, ok=False)
                self.assertFalse((self.state / "guard").exists())
        for value, expected in (("on", "60"), ("3600", "3600"), ("off", "off")):
            self.invoke("control.sh", "guard", value)
            self.assertEqual((self.state / "guard").read_text().strip(), expected)
        self.assertEqual(self.calls(True), [])

    def test_boot_checks_are_bounded_and_do_not_repeat_writes(self) -> None:
        self.invoke("service.sh")
        self.assert_pair("launch_google_search", "0")
        self.assertEqual((self.db / "elapsed").read_text().strip(), "120")
        self.assertEqual(len(self.calls(True)), 2)
        self.assertFalse((self.run_dir / "service").exists())
        self.assertEqual(len((self.state / "service.log").read_text(encoding="utf-8").splitlines()), 1)

    def test_boot_waits_for_android_readiness(self) -> None:
        self.write(self.db / "boot", "0\n")
        self.write(self.db / "boot-at", "20\n")
        self.invoke("service.sh")
        self.assertEqual((self.db / "elapsed").read_text().strip(), "140")
        self.assert_pair("launch_google_search", "0")

    def test_boot_wait_has_a_deadline(self) -> None:
        self.write(self.db / "boot", "0\n")
        self.invoke("service.sh", ok=False)
        self.assertEqual(self.calls(), [])
        self.assertEqual((self.db / "elapsed").read_text().strip(), "180")
        self.assertFalse((self.run_dir / "service").exists())

    def test_boot_read_failure_is_logged_and_returns_failure(self) -> None:
        self.write(self.db / "read-failure", "1\n")
        self.invoke("service.sh", ok=False)
        self.assertEqual(self.calls(True), [])
        self.assertIn("校正失败", (self.state / "service.log").read_text(encoding="utf-8"))

    def test_boot_rechecks_repair_hyperos_rewrite(self) -> None:
        self.write(self.db / "rewrite-at", "30\n")
        self.invoke("service.sh")
        self.assert_pair("launch_google_search", "0")
        self.assertEqual(len(self.calls(True)), 4)

    def test_action_during_boot_changes_later_rechecks(self) -> None:
        self.write(self.db / "action-at", "30\n")
        self.invoke("service.sh")
        self.assert_pair(None, "1")
        self.assertEqual((self.state / "mode").read_text().strip(), "xiaoai")
        self.assertEqual(len(self.calls(True)), 4)

    def test_opt_in_guard_repairs_and_stops_when_disabled(self) -> None:
        self.write(self.state / "guard", "60\n")
        self.write(self.db / "rewrite-at", "130\n")
        self.write(self.db / "disable-at", "240\n")
        self.invoke("service.sh")
        self.assert_pair("launch_google_search", "0")
        self.assertEqual(len(self.calls(True)), 4)
        self.assertEqual((self.db / "elapsed").read_text().strip(), "240")

    def test_guard_off_during_sleep_prevents_another_repair(self) -> None:
        self.write(self.state / "guard", "60\n")
        self.write(self.db / "rewrite-at", "130\n")
        self.write(self.db / "guard-off-at", "130\n")
        self.invoke("service.sh")
        self.assert_pair(None, "1")
        self.assertEqual(len(self.calls(True)), 2)

    def test_disabled_or_removed_module_cannot_switch(self) -> None:
        for flag in ("disable", "remove"):
            with self.subTest(flag=flag):
                (self.module / flag).touch()
                self.invoke("control.sh", "toggle", ok=False)
                self.invoke("service.sh", ok=False)
                self.assertEqual(self.calls(True), [])
                (self.module / flag).unlink()

    def test_two_concurrent_toggles_are_serialized(self) -> None:
        self.env["MOCK_REAL_SLEEP"] = "1"
        (self.db / "slow-write").touch()
        args = [*SHELL, shell_path(self.module / "control.sh"), "toggle"]
        processes = [subprocess.Popen(args, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        try:
            for proc in processes:
                stdout, stderr = proc.communicate(timeout=20)
                self.assertEqual(proc.returncode, 0, stdout.decode("utf-8") + stderr.decode("utf-8"))
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
        self.assert_pair(None, "1")
        self.assertEqual((self.state / "mode").read_text().strip(), "xiaoai")
        self.assertEqual([line.split("|")[2] for line in self.calls(True)], ["system", "global", "system", "global"])

    def test_busy_lock_times_out_without_writes(self) -> None:
        (self.run_dir / "operation").mkdir(parents=True)
        self.invoke("control.sh", "toggle", ok=False)
        self.assertEqual(self.calls(True), [])
        self.assertTrue((self.run_dir / "operation").exists())

    def test_restore_preserves_absence_empty_null_and_arbitrary_data(self) -> None:
        for system, global_value in ((None, None), ("", ""), ("null", "null"), ("custom=a b;$(id)", "7")):
            with self.subTest(system=system, global_value=global_value):
                for table, value in (("system", system), ("global", global_value)):
                    (self.db / table).unlink(missing_ok=True)
                    if value is not None:
                        self.write(self.db / table, value + "\n")
                (self.module / "disable").unlink(missing_ok=True)
                self.invoke("control.sh", "set", "assistant")
                self.invoke("uninstall.sh")
                self.assert_pair(system, global_value)
                self.assertFalse((self.state / "original").exists())
                self.assertFalse(self.hook.exists())

    def test_manual_restore_pauses_module_before_any_further_checks(self) -> None:
        self.invoke("control.sh", "set", "assistant")
        self.invoke("control.sh", "restore")
        self.assert_pair(None, "1")
        self.assertTrue((self.module / "disable").exists())
        self.assertTrue((self.state / "original").exists())
        self.invoke("control.sh", "toggle", ok=False)

    def test_uninstall_restores_preexisting_assistant_choice(self) -> None:
        self.write(self.db / "system", "launch_google_search\n")
        self.write(self.db / "global", "0\n")
        self.invoke("control.sh", "set", "xiaoai")
        self.invoke("uninstall.sh")
        self.assert_pair("launch_google_search", "0")

    def test_deferred_restore_survives_module_directory_removal(self) -> None:
        self.write(self.db / "system", "original_custom_action\n")
        self.invoke("control.sh", "set", "assistant")
        self.write(self.db / "boot", "0\n")
        self.invoke("uninstall.sh")
        self.assertTrue(self.hook.is_file())
        self.assertTrue((self.state / "original").is_file())
        removed_module = self.module.resolve()
        self.assertEqual(removed_module.parent, self.base.resolve())
        self.assertEqual(removed_module.name, "module with spaces")
        shutil.rmtree(removed_module)  # Verified private TemporaryDirectory fixture.
        self.write(self.db / "boot", "1\n")
        self.invoke(str(self.state / "restore.sh"))
        self.assert_pair("original_custom_action", "1")
        self.assertFalse(self.hook.exists())
        self.assertFalse((self.state / "original").exists())

    def test_failed_deferred_restore_retains_backup_for_next_boot(self) -> None:
        self.invoke("control.sh", "set", "assistant")
        self.write(self.db / "boot", "0\n")
        self.invoke("uninstall.sh")
        self.write(self.db / "boot", "1\n")
        self.write(self.db / "read-failure", "1\n")
        self.invoke(str(self.state / "restore.sh"), ok=False)
        self.assertTrue(self.hook.exists())
        self.assertTrue((self.state / "original").exists())
        (self.db / "read-failure").unlink()
        self.invoke(str(self.state / "restore.sh"))
        self.assert_pair(None, "1")
        self.assertFalse(self.hook.exists())

    def test_reinstall_cancels_pending_restore_and_retains_backup(self) -> None:
        self.invoke("control.sh", "set", "assistant")
        original = (self.state / "original").read_bytes()
        self.write(self.db / "boot", "0\n")
        self.invoke("uninstall.sh")
        self.env.update(MODPATH=shell_path(self.module), BOOTMODE="true", API="36")
        harness = self.base / "install-test.sh"
        self.write(harness, '''#!/bin/sh
ui_print() { printf '%s\\n' "$*"; }
abort() { printf '%s\\n' "$*" >&2; exit 1; }
set_perm_recursive() { :; }
set_perm() { :; }
. "$MODPATH/customize.sh"
''')
        self.invoke(str(harness))
        self.assertEqual((self.state / "original").read_bytes(), original)
        self.assertEqual((self.state / "mode").read_text().strip(), "assistant")
        self.assertFalse(self.hook.exists())
        self.assertFalse((self.state / "uninstalling").exists())

    def test_non_root_cannot_modify_state(self) -> None:
        self.env["MOCK_UID"] = "2000"
        self.invoke("control.sh", "set", "assistant", ok=False)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.state / "original").exists())


class BuildTest(unittest.TestCase):
    def test_zip_is_deterministic_and_has_android_permissions(self) -> None:
        spec = importlib.util.spec_from_file_location("has_build", ROOT / "tools/build.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as folder:
            archive = builder.build(Path(folder))
            original_bytes = archive.read_bytes()
            self.assertEqual(builder.build(Path(folder)).read_bytes(), original_bytes)
            with ZipFile(archive) as bundle:
                self.assertIn("module.prop", bundle.namelist())
                self.assertIn("name=HyperOS 助理切换", bundle.read("module.prop").decode("utf-8"))
                self.assertIn("skip_mount", bundle.namelist())
                self.assertNotIn("module/module.prop", bundle.namelist())
                self.assertFalse(any(name.startswith(("system/", ".git/", "tests/")) for name in bundle.namelist()))
                self.assertIsNone(bundle.testzip())
                for entry in bundle.infolist():
                    content = bundle.read(entry)
                    self.assertNotIn(b"\r", content)
                    self.assertFalse(content.startswith(b"\xef\xbb\xbf"))
                    if entry.filename.endswith(".sh"):
                        self.assertEqual(stat.S_IMODE(entry.external_attr >> 16), 0o755)
            self.assertTrue(archive.with_suffix(".zip.sha256").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
