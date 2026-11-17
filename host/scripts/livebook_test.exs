# Run with `just notebooks` or `mix run scripts/livebook_test.exs PATH`.
# Skip the Mix.install and runtime installation cells: use the checkout
# and KETTLECORN_RUNTIME. Preserve bindings between the remaining cells.
path = System.argv() |> hd() |> Path.expand()
source = File.read!(path)

cells =
  for [{start, length}] <-
        Regex.scan(~r/^```elixir\n(.*?)^```/ms, source, capture: :all_but_first, return: :index) do
    preceding = binary_part(source, 0, start)
    {binary_part(source, start, length), length(String.split(preceding, "\n"))}
  end

[{setup, _}, {install, _} | cells] = cells

if !String.contains?(setup, "Mix.install") or !String.contains?(install, "Kettlecorn.Install.runtime"),
  do: raise(ArgumentError, "#{path}: expected the Mix.install cell, then the install cell")

if !System.get_env("KETTLECORN_RUNTIME"),
  do: raise(ArgumentError, "set KETTLECORN_RUNTIME to the runtime to run the notebook against")

Enum.reduce(cells, {[], Code.env_for_eval(file: path)}, fn {code, line}, {binding, env} ->
  try do
    quoted = Code.string_to_quoted!(code, file: path, line: line)
    {_result, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
    {binding, env}
  catch
    kind, reason ->
      IO.puts(:stderr, "#{Path.relative_to_cwd(path)}: the cell at line #{line} failed")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end)

IO.puts("#{Path.relative_to_cwd(path)}: #{length(cells)} cells ran")
