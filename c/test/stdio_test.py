import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def frame(kind, payload=b""):
    return struct.pack(">IB", len(payload) + 1, kind) + payload


class StdioTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.path = Path(cls.directory.name)
        erlang = subprocess.check_output(
            ["erl", "-noshell", "-eval", 'io:format("~s", [code:root_dir()]), halt().'],
            text=True,
        )
        subprocess.run(
            ["erlc", "-o", str(cls.path), str(ROOT / "test/bridge_test.erl")], check=True,
        )
        subprocess.run(
            [
                os.environ.get("CC", "cc"), "-shared", "-fPIC", "-pthread", "-D__wasi__",
                "-D__real_write=write", "-D__real_writev=writev",
                "-I" + erlang + "/usr/include", "-I" + str(ROOT / "include"),
                "-I" + str(ROOT / "http"),
                str(ROOT / "test/bridge_test.c"),
                *(["-undefined", "dynamic_lookup"] if sys.platform == "darwin" else []),
                "-o", str(cls.path / "bridge_test.so"),
            ],
            check=True,
        )

    def run_bridge(self, operation, framed, data=b"", expected="ok", env=None):
        environment = {**os.environ, "KETTLECORN_FRAMED": str(int(framed))}
        for key, value in (env or {}).items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        return subprocess.run(
            [
                "erl", "-noshell", "-noinput", "-pa", str(self.path), "-eval",
                f'ok = bridge_test:load("{self.path}/bridge_test"), '
                f"{expected} = (catch bridge_test:run({operation})), halt().",
            ],
            env=environment,
            input=data, capture_output=True, timeout=10,
        )

    def assert_fatal(self, result, framed, message):
        self.assertEqual(result.returncode, 1)
        if framed:
            self.assertEqual(result.stdout, frame(4, message))
            self.assertEqual(result.stderr, b"")
        else:
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, message + b"\n")

    def test_startup_failure(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                self.assert_fatal(
                    self.run_bridge('startup_failure', framed), framed,
                    b"kettlecorn: can't start the stdio bridge",
                )

    def test_queue_allocation_failure(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                self.assert_fatal(
                    self.run_bridge("queue_allocation_failure" if framed else "allocation_failure", framed, frame(17, b"x") if framed else b"x"),
                    framed, b"kettlecorn: out of memory queueing stdin",
                )

    def test_read_failure(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                self.assert_fatal(
                    self.run_bridge('read_failure', framed), framed, b"kettlecorn: reading stdin failed",
                )

    def test_frame_allocation_failure(self):
        self.assert_fatal(
            self.run_bridge('allocation_failure', True, frame(17, b"x")), True,
            b"kettlecorn: out of memory reading a frame",
        )

    def test_invalid_and_truncated_frames(self):
        for data, message in (
            (b"\0\0\0\0", b"kettlecorn: invalid frame length from the host"),
            (struct.pack(">I", 64 * 1024 * 1024 + 1), b"kettlecorn: invalid frame length from the host"),
            (b"\0\0", b"kettlecorn: truncated frame from the host"),
            (frame(17, b"abc")[:-1], b"kettlecorn: truncated frame from the host"),
        ):
            with self.subTest(data=data):
                self.assert_fatal(self.run_bridge('read_input', True, data), True, message)

    def test_clean_eof(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                result = self.run_bridge('read_input', framed)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_output_policy(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                result = self.run_bridge('output', framed)
                self.assertEqual(result.returncode, 0)
                expected = frame(1, b"out") + frame(2, b"error") + frame(3, b"message") if framed else b"out"
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, b"" if framed else b"error")

    def test_otp_fatal_report(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                result = self.run_bridge('otp_fatal', framed)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, frame(4, b"fatal") if framed else b"")
                self.assertEqual(result.stderr, b"")

    def test_stdin_reads_drain_queued_bytes_before_eof(self):
        result = self.run_bridge(
            'drain_stdin', True, expected='{{ok, <<"ab">>}, {ok, <<"c">>}, {error, closed}}',
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_empty_stdin_read_can_be_followed_by_input(self):
        result = self.run_bridge('empty_stdin', True, expected='{{ok, <<>>}, {ok, <<"x">>}}')
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_stdin_binary_allocation_failures_raise(self):
        for operation in ("binary_allocation_failure", "binary_resize_failure"):
            with self.subTest(operation=operation):
                result = self.run_bridge(operation, True, expected="{'EXIT', {out_of_memory, _}}")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_http_binary_resize_failure_returns_an_error(self):
        result = self.run_bridge("http_binary_resize_failure", True, expected="{error, out_of_memory}")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_reader_registration_owns_and_releases_its_resource(self):
        for operation in ("reader_lifetime", "reader_replacement"):
            with self.subTest(operation=operation):
                result = self.run_bridge(operation, True)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_terminal_dimensions(self):
        for columns, lines, expected in (
            (None, None, "{ok, {80, 24}}"),
            ("120", "40", "{ok, {120, 40}}"),
            ("-1", "-1", "{error, enotsup}"),
            ("oops", "40tail", "{ok, {80, 24}}"),
            ("2147483648", "0", "{ok, {80, 24}}"),
        ):
            with self.subTest(columns=columns, lines=lines):
                result = self.run_bridge(
                    'window_size', True, expected=expected, env={"COLUMNS": columns, "LINES": lines},
                )
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_live_terminal_dimensions(self):
        with tempfile.NamedTemporaryFile(mode="w+") as size:
            for value, expected in (("132 43", "{ok, {132, 43}}"),
                                    ("90 30", "{ok, {90, 30}}"),
                                    ("invalid", "{ok, {80, 24}}")):
                size.seek(0)
                size.truncate()
                size.write(value)
                size.flush()
                result = self.run_bridge('window_size', True, expected=expected,
                                         env={"KETTLECORN_TTY_SIZE": size.name,
                                              "COLUMNS": None, "LINES": None})
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))


if __name__ == "__main__":
    unittest.main()
