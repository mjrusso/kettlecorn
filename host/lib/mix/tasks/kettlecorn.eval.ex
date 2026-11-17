defmodule Mix.Tasks.Kettlecorn.Eval do
  @shortdoc "Evaluates Elixir or Erlang code in a fresh guest VM"
  @moduledoc """
  Evaluates Elixir code, or Erlang with `--erlang`, in a fresh sandboxed VM
  and prints the result.

      mix kettlecorn.eval 'Enum.sum(1..10)'
      mix kettlecorn.eval --erlang 'lists:sum(lists:seq(1, 10)).'
      mix kettlecorn.eval --file script.exs --timeout 2000 --max-memory 268435456

  Options:

    * `--file PATH` - read source from a file instead of a code argument.
    * `--erlang` - evaluate Erlang instead of Elixir.
    * `--timeout MS` - evaluation deadline in milliseconds (default 5000).
      See `Kettlecorn.eval/3` for timeout and cleanup behavior.
    * `--max-memory BYTES` - WebAssembly linear memory cap; see
      `Kettlecorn.Sandbox` for the default.
    * `--runtime DIR` - override normal runtime discovery; see
      `Kettlecorn.Runtime.dir/1` for the search order.

  Prints captured output followed by the inspected result. Evaluator errors
  exit with status 1; other returned errors exit with status 2.
  """
  use Mix.Task

  @switches [
    file: :string,
    erlang: :boolean,
    timeout: :integer,
    max_memory: :integer,
    runtime: :string
  ]

  @impl true
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    code =
      case {opts[:file], args} do
        {nil, [code]} -> code
        {file, []} when is_binary(file) -> File.read!(file)
        _ -> Mix.raise("expected exactly one of: a code argument or --file")
      end

    Mix.Task.run("app.start")

    vm_opts =
      [
        timeout: Keyword.get(opts, :timeout, 5_000),
        language: if(opts[:erlang], do: :erlang, else: :elixir)
      ] ++ Keyword.take(opts, [:max_memory, :runtime])

    case Kettlecorn.run(code, vm_opts) do
      {:ok, %{"output" => output, "inspected" => inspected}} ->
        IO.write(output)
        IO.puts(inspected)

      {:error, %{"output" => output, "message" => message}} ->
        IO.write(output)
        Mix.shell().error(message)
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("VM failed: #{inspect(reason)}")
        exit({:shutdown, 2})
    end
  end
end
