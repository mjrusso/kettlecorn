{ runCommand, unixtools, python3, fish, kettlecorn-run, runtime }:
runCommand "kettlecorn-cli-tests"
{
  nativeBuildInputs = [ kettlecorn-run python3 fish unixtools.ps ];
  env.LANG = "C.UTF-8";
}
  ''
    export HOME=$TMPDIR
    set -x
    kettlecorn-run --help | grep -F 'deleted afterwards.'
    KETTLECORN_MIX=1 kettlecorn-run --iex -h | grep -F 'kettlecorn-run [options]'
    for cli_args in '--unknown-option' '--unknown-option --iex' '--iex --unknown-option'; do
      cli_status=0
      KETTLECORN_MIX=1 kettlecorn-run $cli_args > invalid.out 2> invalid.err || cli_status=$?
      test "$cli_status" -eq 64
      grep -F 'unknown option --unknown-option' invalid.err
    done
    mkdir runtime
    cp -R ${runtime}/launch runtime/
    chmod -R u+w runtime/launch
    for file in manifest.json root beam.wasm beam-http.wasm bin; do ln -s ${runtime}/$file runtime/$file; done
    printf '\n' >> runtime/launch/env
    kettlecorn-run --runtime "$PWD/runtime" --network -e 'IO.puts(:launch_ok)' | grep -x launch_ok
    kettlecorn-run ${../examples/01_hello.exs} one two | grep -F 'Arguments: ["one", "two"]'
    kettlecorn-run -e 'IO.puts(Enum.sum(1..10))' | grep -x 55
    KETTLECORN_MIX=1 kettlecorn-run -e 'IO.puts(:no_parent_pipe)' 3<&- | grep -x no_parent_pipe
    cli_status=0
    kettlecorn-run -e ':erlang.halt(~c"kettlecorn-fatal-test")' > fatal.out 2> fatal.err || cli_status=$?
    test "$cli_status" -eq 1
    test "$(tr -d '\r' < fatal.err | grep -cx kettlecorn-fatal-test)" -eq 1
    printf 'during boot\n' | kettlecorn-run -e 'IO.write(IO.gets(""))' | grep -x 'during boot'

    # A module loaded on demand after preload is reported on stderr without
    # framing, also when loading it is the script's last action.
    cat > late.exs <<'EOF'
    forms = [
      {:attribute, 1, :module, :kettlecorn_late},
      {:attribute, 1, :export, [answer: 0]},
      {:function, 1, :answer, 0, [{:clause, 1, [], [], [{:integer, 1, 42}]}]}
    ]
    {:ok, :kettlecorn_late, beam} = :compile.forms(forms)
    File.mkdir_p!("/tmp/late")
    File.write!("/tmp/late/kettlecorn_late.beam", beam)
    :code.add_patha(~c"/tmp/late")
    :kettlecorn_late.answer()
    EOF
    kettlecorn-run --preload on late.exs 2> late.err
    grep -Fx 'kettlecorn: kettlecorn_late was loaded after preload' late.err
    cli_status=0
    kettlecorn-run --preload strict late.exs 2> strict.err || cli_status=$?
    test "$cli_status" -eq 1
    grep -Fx 'kettlecorn: kettlecorn_late was loaded after preload' strict.err
    # Also when an exit hook registers the hook that loads it.
    sed '$d' late.exs > late-hook.exs
    echo 'System.at_exit(fn _ -> System.at_exit(fn _ -> :kettlecorn_late.answer() end) end)' >> late-hook.exs
    cli_status=0
    kettlecorn-run --preload strict late-hook.exs 2> hook.err || cli_status=$?
    test "$cli_status" -eq 1
    grep -Fx 'kettlecorn: kettlecorn_late was loaded after preload' hook.err
    printf 'x = 6 * 7\nIO.puts("x=#{x}")\n' | kettlecorn-run --iex | grep -F 'x=42'
    printf ':ok\n' | kettlecorn-run --iex -e 'IO.puts(:iex_eval)' | grep -x iex_eval
    printf 'IO.puts(:iex_script)\n' > iex.exs
    printf ':ok\n' | kettlecorn-run --iex "$PWD/iex.exs" | grep -x iex_script

    mkdir instances
    for cli_signal in TERM INT; do
      # Start with default signals so the launcher can trap SIGINT.
      (
        trap - INT QUIT
        export TMPDIR="$PWD/instances"
        exec kettlecorn-run --timeout 10s \
          -e 'IO.puts("ready"); Process.sleep(:infinity)'
      ) > signal.log &
      cli_pid=$!
      trap 'kill -KILL "$cli_pid" 2>/dev/null || true' EXIT
      for attempt in $(seq 1 100); do
        if grep -q ready signal.log; then break; fi
        sleep 0.1
      done
      grep -q ready signal.log
      kill -s "$cli_signal" "$cli_pid"
      for attempt in $(seq 1 30); do
        if ! kill -0 "$cli_pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      if kill -0 "$cli_pid" 2>/dev/null; then
        echo "kettlecorn-run did not stop after SIG$cli_signal" >&2
        exit 1
      fi
      cli_status=0
      wait "$cli_pid" || cli_status=$?
      case "$cli_signal" in
        TERM) test "$cli_status" -eq 143 ;;
        INT) test "$cli_status" -eq 130 ;;
      esac
      trap - EXIT
      test -z "$(ls -A instances)"
      cli_processes=$(ps -A -o args=)
      [[ "$cli_processes" != *"$PWD/instances/"* ]]
    done
    python3 ${../tests/cli/terminal_test.py} kettlecorn-run
    python3 ${../tests/cli/quoting_test.py} ${runtime}
    python3 ${../tests/cli/startup_test.py} ${runtime}
    python3 ${../tests/cli/output_deadline_test.py} ${runtime} kettlecorn-run
    touch $out
  ''
