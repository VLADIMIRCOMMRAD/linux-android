# Installer regression tests

Run `python3 tests/test_installers.py` from the repository root. Bash is required; set `BASH` to its executable path if it is not on PATH.

The tests use temporary directories and mocked Android services and package commands. They check generated desktop launchers, CLI guards, failure handling, and Home Assistant configuration preservation without installing packages. Real-device tests are still needed for display, audio, GPU and package compatibility.
