defmodule Mix.Tasks.Kettlecorn.Run do
  @shortdoc "Runs guest code or prints a command for guest IEx"
  @moduledoc """
  Runs the installed runtime's `kettlecorn-run` with the supplied arguments.

      mix kettlecorn.run script.exs arg1 arg2
      mix kettlecorn.run -e 'IO.puts(Enum.sum(1..10))'
      mix kettlecorn.run --iex
      mix kettlecorn.run --app _kettlecorn --iex

  See the [CLI guide](running-applications.md#command-line) for installation,
  runtime selection, options, and the standalone command printed for IEx.
  """
  use Mix.Task
  alias Kettlecorn.Runtime

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    {opts, argv} =
      case argv do
        ["--runtime", dir | rest] -> {[runtime: dir], rest}
        _ -> {[], argv}
      end

    runtime =
      case Runtime.find(opts) do
        {:ok, runtime} -> runtime
        {:error, message} -> Mix.raise(message)
      end

    # nouse_stdio leaves the port input pipe on fd 3 for parent-exit cleanup.
    {_output, status} =
      System.cmd(Runtime.cli(runtime), ["--runtime", runtime.dir | argv],
        use_stdio: false,
        env: [{"KETTLECORN_MIX", "1"}]
      )

    case status do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
