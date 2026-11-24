import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


runtime = Path(sys.argv[1])
runner = sys.argv[2]
launcher = runtime / "bin/kettlecorn-launch"
output = 'IO.binwrite(:binary.copy("x", 8192))'
# The lifetime includes guest boot, which needs several seconds on busy CI workers.
timeout_seconds = 30


def expect_failure(command, **options):
    reader, writer = os.pipe()
    try:
        if hasattr(fcntl, "F_SETPIPE_SZ"):
            try:
                fcntl.fcntl(writer, fcntl.F_SETPIPE_SZ, 1024 * 1024)
            except OSError:
                pass
        os.set_blocking(writer, False)
        try:
            while True:
                os.write(writer, b"x" * 65536)
        except BlockingIOError:
            pass
        with subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=writer,
            stderr=subprocess.PIPE,
            start_new_session=True,
            **options,
        ) as process:
            try:
                process.wait(timeout=timeout_seconds + 5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise AssertionError("launcher did not stop with an open, unread stdout pipe")
            assert process.returncode == 1, process.stderr.read()
    finally:
        os.close(writer)
        os.close(reader)


with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    root = directory / "root"
    base = [str(launcher), "--runtime", str(runtime), "--root", str(root)]
    subprocess.run(base + ["--prepare-root"], check=True)
    subprocess.run(
        base + ["--timeout", f"{timeout_seconds}s", "--", "-e", ":ok"],
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
    )
    for name, code in [
        (
            "exit",
            output + '; File.write!("/finished", "done"); :erlang.halt(0)',
        ),
        ("running", output + "; Process.sleep(:infinity)"),
    ]:
        stderr = directory / name
        expect_failure(
            base
            + ["--stderr", str(stderr), "--timeout", f"{timeout_seconds}s", "--", "-e", code]
        )
        marker = json.loads(stderr.with_suffix(".stopped").read_text())
        assert marker["outcome"] == "timeout" and "fuel_consumed" not in marker, marker
        if name == "exit":
            assert (root / "finished").read_text() == "done"

    fuel = ["--fuel", "3000000000"]
    subprocess.run(
        base + fuel + ["--timeout", f"{timeout_seconds}s", "--", "-e", ":ok"],
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
    )
    stderr = directory / "fuel"
    expect_failure(
        base
        + fuel
        + [
            "--stderr",
            str(stderr),
            "--",
            "-e",
            output
            + '; File.write!("/fuel_started", "done"); '
            + "Stream.repeatedly(fn -> 1 end) |> Stream.run()",
        ]
    )
    marker = json.loads(stderr.with_suffix(".stopped").read_text())
    assert marker["outcome"] == "out_of_fuel", marker
    assert marker["fuel_consumed"] == 3_000_000_000, marker
    assert (root / "fuel_started").read_text() == "done"

    instances = directory / "instances"
    instances.mkdir()
    expect_failure(
        [runner, "--runtime", str(runtime), "--timeout", f"{timeout_seconds}s", "-e", output],
        env={**os.environ, "TMPDIR": str(instances)},
    )
    assert not list(instances.iterdir()), "CLI left a private root after timeout"

print("output deadline, fuel exhaustion, termination publication, and CLI cleanup: ok")
