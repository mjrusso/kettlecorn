defmodule Mix.Tasks.Kettlecorn.Cook do
  @shortdoc "Packages the current Mix application for a Kettlecorn guest"
  @moduledoc """
  Compiles the current project and packages it, with its dependencies, for
  the guest (see `Kettlecorn.Cook`).

  Cooking runs project code, dependencies, compiler hooks, and configuration on
  the host with the build user's permissions. Cook trusted projects or isolate
  fetching and building separately. The guest sandbox applies when the bundle runs.

      MIX_ENV=prod mix kettlecorn.cook
      mix kettlecorn.install --dir .kettlecorn-runtime
      MIX_ENV=prod mix kettlecorn.cook --out _kettlecorn --runtime .kettlecorn-runtime

  Add Kettlecorn to the project for the task only:

      {:kettlecorn, "~> 0.1", runtime: false, only: [:dev, :prod]}

  Options:

    * `--out` - output path (default `_kettlecorn`). Cooking publishes a symbolic
      link after a successful cook. Use a path you own. Cooking can overwrite
      an existing file there. Move an existing ordinary directory aside first.
      See `Kettlecorn.Cook.cook/1` for retained copies.
    * `--app` - entrypoint application (default: the current project's).
    * `--root` - another application to cook with its dependencies (see
      `:roots` in `Kettlecorn.Cook.cook/1`); can be given more than once.
    * `--runtime` - runtime to check the dependencies against (default
      `$KETTLECORN_RUNTIME`, if set).

  Compile the project with the runtime's OTP major release and exact Elixir
  version, recorded in `manifest.json`. Then run it:

      .kettlecorn-runtime/bin/kettlecorn-run --app _kettlecorn
      .kettlecorn-runtime/bin/kettlecorn-run --app _kettlecorn --iex
      .kettlecorn-runtime/bin/kettlecorn-run --app _kettlecorn script.exs

  or from a host program with `Kettlecorn.start_link(app: "_kettlecorn")`.
  """
  use Mix.Task

  @switches [out: :string, app: :string, root: :keep, runtime: :string]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")

    config = Mix.Project.config()

    result =
      Kettlecorn.Cook.cook(
        app: opts[:app] || config[:app],
        roots: Keyword.get_values(opts, :root),
        build: Path.join(Mix.Project.build_path(), "lib"),
        out: opts[:out] || "_kettlecorn",
        config: config[:config_path],
        env: Mix.env(),
        runtime: opts[:runtime] || Kettlecorn.Runtime.env("KETTLECORN_RUNTIME")
      )

    case result do
      {:ok, %{app: app, apps: apps}} ->
        Mix.shell().info(
          "Cooked #{app} into #{opts[:out] || "_kettlecorn"} (applications: #{length(apps)})"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
