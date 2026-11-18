"""Run printed IEx commands in POSIX sh and Fish."""
import os
import subprocess
import sys


runtime = sys.argv[1]
arguments = [
    "quote's", "trailing\\", "two\\\\slashes", "a&b", "$(printf unsafe)",
    "`printf unsafe`", "", "line one\nline two\n",
]
code = 'IO.binwrite("ARGV:" <> Enum.join(System.argv(), <<0>>)); System.halt(0)'
expected = "\0".join(arguments).encode()
environment = dict(os.environ)
for name in ("KETTLECORN_RUNTIME", "KETTLECORN_MIX", "BASH_COMPAT"):
    environment.pop(name, None)

# Level 32 checks legacy shell behavior, not the Bash 3.2 parser.
for compatibility in (None, "32"):
    printing = dict(environment, KETTLECORN_MIX="1")
    if compatibility:
        printing["BASH_COMPAT"] = compatibility
    command = subprocess.run(
        [f"{runtime}/bin/kettlecorn-run", "--runtime", runtime, "--iex", "-e", code,
         "--", *arguments],
        env=printing, capture_output=True, text=True, check=True, timeout=30,
    ).stdout.strip()
    for shell in (["sh"], ["fish", "--no-config"]):
        result = subprocess.run(
            [*shell, "-c", command], env=environment, capture_output=True, check=True, timeout=30,
        )
        _, marker, actual = result.stdout.partition(b"ARGV:")
        assert marker and actual == expected, (shell, compatibility, result.stdout, result.stderr)

print("printed IEx arguments in sh and Fish, default and compatibility mode: ok")
