#!/usr/bin/env python3
"""Offline regressions for installer control flow and generated launchers.

No packages, Android services, or real user configuration are touched. Run with
python3 tests/test_installers.py; set BASH to a Bash executable if it is not on PATH.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH") or shutil.which("bash")


@unittest.skipUnless(BASH, "Bash is required (set BASH to its executable path)")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="linux-android-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.home = self.root / "home"
        self.prefix = self.root / "usr"
        self.home.mkdir()
        (self.prefix / "bin").mkdir(parents=True)
        (self.prefix / "tmp").mkdir()
        self.env = os.environ.copy()
        # These overrides affect only child shells inside this disposable directory.
        self.env.update(HOME=self.home.as_posix(), PREFIX=self.prefix.as_posix(),
                        TMPDIR=(self.prefix / "tmp").as_posix())
        self.env["TEST_ROOT"] = self.root.as_posix()
        self.env["TEST_REPO"] = REPO.as_posix()
        for name in ("termux-linux-setup.sh", "setup-homeassistant.sh"):
            text = (REPO / name).read_text(encoding="utf-8")
            entrypoint = 'parse_args "$@"\nmain "$@"'
            self.assertTrue(text.rstrip().endswith(entrypoint), name)
            # Remove only the known entrypoint. Sourcing must never install anything.
            definitions = text.rstrip()[: -len(entrypoint)]
            (self.root / name).write_text(definitions, encoding="utf-8", newline="\n")

    def shell(self, script, expected=0):
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-c", script],
            env=self.env,
            cwd=REPO,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, expected, result.stdout)
        return result.stdout

    def assert_shell_syntax(self, paths):
        for path in paths:
            with self.subTest(generated=path.name):
                self.assertTrue(path.is_file(), str(path))
                self.env["TEST_SCRIPT"] = path.as_posix()
                self.shell('bash -n "$TEST_SCRIPT"')

    def test_cli_help_invalid_flags_and_non_termux_guard(self):
        for name, help_flag in (
            ("termux-linux-setup.sh", "--de"),
            ("setup-homeassistant.sh", "--no-hacs"),
        ):
            with self.subTest(installer=name):
                self.env["TEST_SCRIPT"] = (REPO / name).as_posix()
                self.assertIn(help_flag, self.shell('bash "$TEST_SCRIPT" --help'))
                self.shell('bash "$TEST_SCRIPT" --bogus', expected=2)
                # Existing but empty PREFIX deliberately contains no Termux pkg command.
                output = self.shell('bash "$TEST_SCRIPT" -y </dev/null', expected=1)
                self.assertIn("must be run inside Termux", output)
        self.env["TEST_SCRIPT"] = (REPO / "termux-linux-setup.sh").as_posix()
        for flags in ("--de", "--de nope", "--de="):
            with self.subTest(flags=flags):
                self.shell(f'bash "$TEST_SCRIPT" {flags}', expected=2)

    def test_desktop_generation_is_inert_and_all_sessions_launch(self):
        for choice, name, command in (
            (1, "XFCE4", "startxfce4"),
            (2, "LXQt", "startlxqt"),
            (3, "MATE", "mate-session"),
            (4, "KDE Plasma", "startplasma-x11"),
        ):
            for gpu in ("freedreno", "swrast"):
                with self.subTest(desktop=name, gpu=gpu):
                    self.env.update(TEST_DE=str(choice), TEST_DE_NAME=name, TEST_GPU=gpu)
                    self.shell(r'''
source "$TEST_ROOT/termux-linux-setup.sh"
update_progress() { :; }
DE_CHOICE=$TEST_DE
DE_NAME=$TEST_DE_NAME
GPU_DRIVER=$TEST_GPU
# Any command substitution that starts a service during generation leaves proof.
pulseaudio() { echo pulseaudio >> "$TEST_ROOT/unexpected"; }
pactl() { echo pactl >> "$TEST_ROOT/unexpected"; }
termux-x11() { echo termux-x11 >> "$TEST_ROOT/unexpected"; }
step_launchers
step_shortcuts
''')
                    self.assertFalse((self.root / "unexpected").exists(),
                                     "Generating launchers executed a service command")
                    scripts = [self.home / "start-linux.sh", self.home / "stop-linux.sh",
                               self.home / ".config/linux-gpu.sh"]
                    if choice == 4:
                        scripts.append(self.home / ".config/plasma-workspace/env/xdg_fix.sh")
                    self.assert_shell_syntax(scripts)
                    # Exercise actual generated control flow, replacing every service,
                    # delay, and exec. All filesystem paths remain in the sandbox.
                    output = self.shell(r'''
pkill() { :; }
sleep() { :; }
dbus-uuidgen() { :; }
dbus-daemon() { :; }
dbus-update-activation-environment() { :; }
pulseaudio() { :; }
pactl() { :; }
termux-x11() { :; }
startxfce4() { :; }
startlxqt() { :; }
mate-session() { :; }
startplasma-x11() { :; }
timeout() { return 124; }
exec() { printf 'SESSION:%s\n' "$*"; }
source "$HOME/start-linux.sh"
''')
                    self.assertIn(f"SESSION:{command}\n", output)

    def test_homeassistant_launcher_syntax(self):
        self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
update_progress() { :; }
step_launchers
''')
        self.assert_shell_syntax([self.home / f"{verb}-homeassistant.sh"
                                  for verb in ("start", "stop", "upgrade")])

    def test_desktop_required_package_failure_stops_installation(self):
        output = self.shell(r'''
source "$TEST_ROOT/termux-linux-setup.sh"
pkg() { :; }
pkg_installed() { return 1; }
provider_of() { :; }
apt-cache() { return 1; }
show_banner() { :; }
setup_environment() { :; }
step_update() { :; }
step_repos() { :; }
step_x11() { safe_install_pkg dbus D-Bus; }
step_desktop() { :; }
step_gpu() { echo UNEXPECTED_GPU; }
step_audio() { :; }
step_apps() { :; }
step_python() { :; }
step_launchers() { echo UNEXPECTED_LAUNCHERS; }
step_shortcuts() { :; }
show_completion() { echo UNEXPECTED_COMPLETION; }
(main)
status=$?
[ "$status" -ne 0 ] || exit 1
''')
        self.assertIn("dbus", output)
        self.assertIn("incomplete", output)
        self.assertNotIn("UNEXPECTED_", output)

    def test_missing_turnip_driver_uses_software_rendering(self):
        self.shell(r'''
source "$TEST_ROOT/termux-linux-setup.sh"
update_progress() { :; }
GPU_DRIVER=freedreno
GPU_STACK=stock
step_launchers
''')
        missing = self.shell(r'''
export VK_ICD_FILENAMES=/missing/old-driver.json
source "$HOME/.config/linux-gpu.sh"
printf 'GPU:%s ICD:%s SOFTWARE:%s\n' "$GALLIUM_DRIVER" "$VK_ICD_FILENAMES" "$LIBGL_ALWAYS_SOFTWARE"
''')
        self.assertIn("GPU:llvmpipe ICD: SOFTWARE:1", missing)
        icd = self.prefix / "share/vulkan/icd.d/freedreno_icd.aarch64.json"
        icd.parent.mkdir(parents=True)
        icd.write_text("{}", encoding="utf-8")
        present = self.shell(r'''
source "$HOME/.config/linux-gpu.sh"
printf 'GPU:%s ICD:%s\n' "$GALLIUM_DRIVER" "$VK_ICD_FILENAMES"
''')
        self.assertIn(f"GPU:zink ICD:{icd.as_posix()}", present)

    def test_homeassistant_preserves_existing_configuration(self):
        config_dir = self.home / "hass-config"
        config_dir.mkdir()
        config = config_dir / "configuration.yaml"
        original = b"# My custom configuration\nhttp:\n  server_port: 9123\nautomation: !include automations.yaml\n"
        config.write_bytes(original)
        self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
update_progress() { :; }
proot-distro() {
    [ "$1 $2 $3" = "login ubuntu --" ] || return 90
    shift 3
    "$@"
}
step_ha_config
''')
        self.assertEqual(config.read_bytes(), original)

    def test_homeassistant_creates_configuration_once(self):
        self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
update_progress() { :; }
proot-distro() {
    [ "$1 $2 $3" = "login ubuntu --" ] || return 90
    shift 3
    "$@"
}
step_ha_config
''')
        config = self.home / "hass-config/configuration.yaml"
        self.assertTrue(config.is_file())
        self.assertIn("http:", config.read_text(encoding="utf-8"))

    def test_homeassistant_removed_packages_are_reinstalled(self):
        for status in ("installed", "config-files", ""):
            with self.subTest(dpkg_status=status):
                self.env["TEST_PACKAGE_STATUS"] = status
                output = self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
proot-distro() {
    case "$4" in
        dpkg-query) printf '%s' "$TEST_PACKAGE_STATUS" ;;
        bash) echo INSTALL_ATTEMPT >> "$TEST_ROOT/package-installs" ;;
        *) return 90 ;;
    esac
}
spinner() { wait "$1"; }
proot_install_pkg python3 Python
''')
                marker = self.root / "package-installs"
                if status == "installed":
                    self.assertIn("already installed", output)
                    self.assertFalse(marker.exists())
                else:
                    self.assertTrue(marker.exists(), "Removed package was skipped")
                    marker.unlink()

    def test_homeassistant_required_failure_stops_before_launchers(self):
        output = self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
pkg() { :; }
show_banner() { :; }
preflight_checks() { :; }
step_proot() { :; }
step_ubuntu() { :; }
step_ubuntu_deps() { :; }
step_homeassistant() { return 23; }
step_ha_config() { echo UNEXPECTED_CONFIG; }
step_launchers() { echo UNEXPECTED_LAUNCHERS; }
step_verify() { echo UNEXPECTED_VERIFY; }
show_completion() { echo UNEXPECTED_COMPLETION; }
(main)
status=$?
[ "$status" -ne 0 ] || exit 1
''')
        self.assertNotIn("UNEXPECTED_", output)

    def test_homeassistant_upgrade_failure_is_not_reported_as_success(self):
        output = self.shell(r'''
source "$TEST_ROOT/setup-homeassistant.sh"
update_progress() { :; }
step_launchers
pkill() { :; }
sleep() { :; }
termux-wake-lock() { :; }
termux-wake-unlock() { echo WAKE_LOCK_RELEASED; }
proot-distro() {
    case "$*" in
        *" install "*"--upgrade homeassistant"*) return 23 ;;
        *"--version"*) echo 2026.2.3 ;;
        *) return 90 ;;
    esac
}
(source "$HOME/upgrade-homeassistant.sh")
status=$?
[ "$status" -ne 0 ] || exit 1
''')
        self.assertNotIn("No change.", output)
        self.assertIn("WAKE_LOCK_RELEASED", output)


if __name__ == "__main__":
    if not BASH:
        raise SystemExit("Bash not found. Set BASH to its executable path.")
    unittest.main(verbosity=2)
