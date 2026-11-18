defmodule Kettlecorn.RunTaskTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "a missing runtime explains how to install it", %{tmp_dir: dir} do
    {output, status} = run_task(["-e", "1"], dir, nil)

    assert status == 1

    assert output =~
             "No Kettlecorn runtime found: run `mix kettlecorn.install`, " <>
               "or set :runtime / KETTLECORN_RUNTIME"
  end

  @tag :integration
  test "help and invalid options are handled by the CLI", %{tmp_dir: dir} do
    assert {help, 0} = run_task(["--iex", "--help"], dir)
    assert help =~ "kettlecorn-run [options]"

    assert {error, 64} = run_task(["--iex", "--unknown-option"], dir)
    assert error =~ "unknown option --unknown-option"
  end

  @tag :integration
  test "an explicit runtime can have a symlinked parent directory", %{tmp_dir: dir} do
    parent = Path.join(dir, "real")
    TestRuntime.fixture(Path.join(parent, "runtime"))
    alias_dir = Path.join(dir, "alias")
    File.ln_s!(parent, alias_dir)

    assert {output, 0} =
             run_task(["--runtime", Path.join(alias_dir, "runtime"), "--iex"], dir, nil)

    assert output =~ "Run this command in your terminal to start IEx:"
  end

  @tag :integration
  test "scripts and expressions preserve guest arguments", %{tmp_dir: dir} do
    script = Path.join(dir, "script with spaces.exs")
    File.write!(script, "IO.inspect(System.argv())")
    args = ["a b", "--runtime", "not-a-runtime", "--iex", "$(echo unsafe)"]

    assert {output, 0} = run_task([script | args], dir)
    assert output =~ inspect(args)

    assert {output, 0} =
             run_task(["-e", "IO.inspect(System.argv())", "--" | args], dir)

    assert output =~ inspect(args)
  end

  @tag :integration
  test "an explicit runtime overrides discovery and preserves the exit status", %{tmp_dir: dir} do
    assert {output, 23} =
             run_task(
               [
                 "--runtime",
                 TestRuntime.runtime(),
                 "--timeout",
                 "30s",
                 "-e",
                 ~s|IO.puts(:stderr, "diagnostic"); System.halt(23)|
               ],
               dir,
               nil
             )

    assert output =~ "diagnostic\n"
  end

  @tag :integration
  test "scripts can read piped input", %{tmp_dir: dir} do
    input_file = Path.join(dir, "stdin")
    File.write!(input_file, "piped input\n")

    assert {output, 0} =
             with_stdin(
               ~S|exec mix kettlecorn.run -e 'IO.write(IO.gets(""))'|,
               input_file,
               task_options(dir, TestRuntime.runtime())
             )

    assert output =~ "piped input\n"
  end

  @tag :integration
  test "IEx prints a runnable command bound to the resolved runtime", %{tmp_dir: dir} do
    runtime_link = Path.join(dir, "selected-runtime")
    File.ln_s!(TestRuntime.runtime(), runtime_link)
    input_file = Path.join(dir, "stdin")
    File.write!(input_file, "IO.puts(:interactive)\n")

    assert {command, 0} =
             System.cmd(
               "mix",
               ["kettlecorn.run", "--runtime", runtime_link, "--iex", "-e", "IO.puts(:loaded)"],
               Keyword.delete(task_options(dir, TestRuntime.runtime()), :stderr_to_stdout)
             )

    refute command =~ "Interactive Elixir"
    File.rm!(runtime_link)

    assert {result, 0} =
             with_stdin(
               String.trim(command),
               input_file,
               task_options(dir, Path.join(dir, "missing-runtime"))
             )

    assert result =~ "Interactive Elixir"
    assert result =~ "loaded\n"
    assert result =~ "interactive\n"
  end

  @tag :integration
  test "exiting the host Mix process stops the CLI and removes its root", %{tmp_dir: dir} do
    instances = Path.join(dir, "instances")
    File.mkdir_p!(instances)

    options = task_options(dir, TestRuntime.runtime())

    environment =
      for {name, value} <- [{"TMPDIR", instances} | options[:env]],
          do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :eof,
        args: [
          "kettlecorn.run",
          "--timeout",
          "30s",
          "-e",
          ~s|IO.puts("ready"); Process.sleep(:infinity)|
        ],
        cd: options[:cd],
        env: environment
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port),
        do: System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    end)

    await_ready(port, "")
    assert Path.wildcard(Path.join(instances, "kettlecorn-run.*")) != []
    assert {_, 0} = System.cmd("kill", ["-TERM", to_string(pid)])
    assert_receive {^port, {:exit_status, _status}}, 10_000
    assert_receive {^port, :eof}, 5_000
    assert Path.wildcard(Path.join(instances, "kettlecorn-run.*")) == []
    Port.close(port)
  end

  defp await_ready(port, output) do
    unless output =~ "ready\n" do
      assert_receive {^port, {:data, chunk}}, 30_000
      await_ready(port, output <> chunk)
    end
  end

  defp run_task(args, dir, runtime \\ TestRuntime.runtime()) do
    System.cmd("mix", ["kettlecorn.run" | args], task_options(dir, runtime))
  end

  defp with_stdin(command, input, options) do
    System.cmd("sh", ["-c", command <> ~s| < "$0"|, input], options)
  end

  defp task_options(dir, runtime) do
    [
      cd: Path.expand("..", __DIR__),
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"KETTLECORN_RUNTIME", runtime},
        {"XDG_CACHE_HOME", Path.join(dir, "cache")},
        {"ERL_FLAGS", "+S 2:2"}
      ]
    ]
  end
end
