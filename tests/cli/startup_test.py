import subprocess
import sys
import tempfile
from pathlib import Path


runtime = Path(sys.argv[1])
launcher = runtime / "bin/kettlecorn-launch"
check = '''
true = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :eex end)
"configured" = System.get_env("STARTUP_TEST")
true = ~c"/work" in :code.get_path()
IO.puts("startup_ok")
'''

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory) / "root"
    base = [str(launcher), "--runtime", str(runtime), "--root", str(root)]
    subprocess.run(base + ["--prepare-root"], check=True)
    (root / "work/startup.exs").write_text(check)
    for mode in [["--", "-e", check], ["--", "/work/startup.exs"], ["--iex"]]:
        result = subprocess.run(
            base
            + ["--app", "eex", "--env", "STARTUP_TEST=configured", "--code-path", "/work"]
            + mode,
            input=check,
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == 0, result
        assert "startup_ok" in result.stdout, result
        assert "MatchError" not in result.stdout + result.stderr, result

    for mode in [[], ["--", "-e", check], ["--", "/work/startup.exs"], ["--iex"]]:
        result = subprocess.run(
            base + ["--app", "no_such_startup_app"] + mode,
            input=check,
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == 1, result
        assert "starting no_such_startup_app failed" in result.stderr, result
        assert "startup_ok" not in result.stdout, result

print("configured applications start before scripts, evaluations, and IEx: ok")
