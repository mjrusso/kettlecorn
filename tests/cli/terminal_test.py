"""Exercise IEx input and live geometry in a real terminal."""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


pid, terminal = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execvp(sys.argv[1], sys.argv[1:] + ["--iex"])


def resize(columns, rows):
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def expect(marker):
    output = bytearray()
    deadline = time.monotonic() + 30
    while marker not in output:
        if time.monotonic() >= deadline:
            raise AssertionError(f"missing {marker!r}: {bytes(output)!r}")
        readable, _, _ = select.select([terminal], [], [], 0.1)
        if readable:
            output.extend(os.read(terminal, 65536))


try:
    resize(80, 24)
    expect(b"iex(1)>")
    geometry = b'IO.puts("GEOMETRY=#{elem(:io.columns(), 1)}x#{elem(:io.rows(), 1)}")\r'
    os.write(terminal, geometry)
    expect(b"GEOMETRY=80x24")
    resize(120, 40)
    time.sleep(0.05)
    os.write(terminal, geometry)
    expect(b"GEOMETRY=120x40")
    os.write(terminal, b'IO.puts("EDIT=" <> Integer.to_string(40 + 1\x7f2))\r')
    expect(b"EDIT=42")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while True:
        stopped, status = os.waitpid(pid, os.WNOHANG)
        if stopped:
            assert os.waitstatus_to_exitcode(status) == 143, status
            break
        assert time.monotonic() < deadline, "launcher did not stop after SIGTERM"
        time.sleep(0.02)
    print("terminal input, live geometry, and shutdown: ok")
finally:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    os.close(terminal)
