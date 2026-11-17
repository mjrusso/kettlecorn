defmodule Kettlecorn.Cook do
  @moduledoc """
  Packages a compiled Mix application and its dependencies for the guest.

  Cooking evaluates configuration on the host. The Mix task also compiles the
  project and its dependencies there. Cook trusted projects or isolate the build
  separately; guest isolation starts when the bundle runs.

  A cooked application is a directory that is copied to the guest's `/app`
  when a VM starts:

      <out>/kettlecorn.json       protocol and compiler compatibility
      <out>/app                   the entrypoint application's name
      <out>/sys.config            its configuration (config/config.exs, read at cook time)
      <out>/lib/<app>/ebin         the application and its dependencies
      <out>/lib/<app>/priv         their priv/ files

  Start the application with `Kettlecorn.start_link(app: "<out>")` or
  `kettlecorn-run --app <out> ...`. The entrypoint starts before the VM
  reports that it booted. Cooked applications replace the runtime's copies
  of the same name, so a bundle can supply its own Req version, for example.

  The guest loads `sys.config` before starting these applications.
  `kernel` and `stdlib` are already running; their settings only affect
  subsequent configuration reads.

  Use it through `mix kettlecorn.cook` inside the project.

  Compile guest code with the runtime's OTP major release and exact Elixir version.
  Guest applications cannot load native NIFs or start OS processes. The packager
  warns about `.so` files in `priv/`.
  `config/runtime.exs` is not evaluated: the guest has no Mix.
  """

  @doc """
  Cooks an application. Options:

    * `:app` (required) - the entrypoint application.
    * `:build` (required) - the build's lib directory, e.g. `_build/prod/lib`.
    * `:out` (required) - output path. Cooking publishes a symbolic link and
      replaces it atomically on subsequent cooks; a failed cook preserves it.
      Move an existing ordinary directory aside first. Previous copies stay in
      `<out>.versions` until removed after their readers have finished.
    * `:config` - a config file to read into `sys.config`, e.g. `config/config.exs`.
    * `:env` - the Mix environment for `:config` (default `:prod`).
    * `:roots` - more applications in `:build` to cook with their
      dependencies, which the entrypoint doesn't depend on (plugins, say,
      started with `Kettlecorn.start_link(apps: ...)`).
    * `:runtime` - check that required dependencies are either cooked or
      available in this runtime directory.

  The bundle includes the entrypoint, extra roots, and their dependencies
  from `:build`, as listed in their `.app` files (`applications` and
  `included_applications`). Available optional dependencies are included too.
  Unrelated build applications, such as Hex and dependencies marked
  `runtime: false`, are omitted. When `:runtime` is supplied, required
  dependencies absent from the build must be present in that runtime.

  Returns `{:ok, %{app: app, apps: cooked_apps}}` or `{:error, message}`.
  """
  def cook(opts) do
    app = opts |> Keyword.fetch!(:app) |> to_atom()
    roots = [app | opts |> Keyword.get(:roots, []) |> Enum.map(&to_atom/1)]
    build = Keyword.fetch!(opts, :build)
    out = Keyword.fetch!(opts, :out)
    built = built_apps(build)

    with {:ok, runtime} <- Kettlecorn.Bundle.runtime(opts[:runtime]),
         :ok <- check_roots(roots, built),
         {:ok, apps} <- closure(roots, built, runtime_apps(runtime)),
         config = sys_config(opts[:config], Keyword.get(opts, :env, :prod)),
         :ok <- Kettlecorn.Dir.replace(out, &write_out(&1, build, app, apps, config)) do
      warn_native(out)
      {:ok, %{app: app, apps: apps}}
    end
  end

  defp write_out(staging, build, app, apps, config) do
    out = Path.join(staging, "out")
    File.mkdir_p!(Path.join(out, "lib"))
    for a <- apps, do: copy_app!(build, out, Atom.to_string(a))
    File.write!(Path.join(out, "kettlecorn.json"), JSON.encode!(Kettlecorn.Bundle.compiler()))
    File.write!(Path.join(out, "app"), Atom.to_string(app))
    File.write!(Path.join(out, "sys.config"), config)
    {:ok, out}
  end

  defp built_apps(build) do
    for name <- File.ls!(build),
        file = Path.join([build, name, "ebin", "#{name}.app"]),
        File.regular?(file),
        into: %{},
        do: {String.to_atom(name), file}
  end

  defp check_roots(roots, built) do
    case Enum.reject(roots, &Map.has_key?(built, &1)) do
      [] ->
        :ok

      absent ->
        found = built |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "not in the build: #{Enum.join(absent, ", ")} (found: #{found})"}
    end
  end

  defp closure(roots, built, runtime) do
    case walk(roots, MapSet.new(roots), built, runtime, []) do
      {cooked, []} ->
        {:ok, cooked |> MapSet.to_list() |> Enum.sort()}

      {_cooked, missing} ->
        list =
          missing
          |> Enum.reverse()
          |> Enum.uniq()
          |> Enum.map_join(", ", fn {a, dep} -> "#{dep} (needed by #{a})" end)

        {:error, "applications not available in the guest: #{list}"}
    end
  end

  defp walk([], cooked, _built, _runtime, missing), do: {cooked, missing}

  defp walk([app | queue], cooked, built, runtime, missing) do
    {required, optional} = app_deps(Map.fetch!(built, app))

    new =
      Enum.filter(
        Enum.uniq(required ++ optional),
        &(Map.has_key?(built, &1) and &1 not in cooked)
      )

    missing =
      Enum.reduce(required, missing, fn dep, acc ->
        if Map.has_key?(built, dep) or runtime == nil or dep in runtime,
          do: acc,
          else: [{app, dep} | acc]
      end)

    walk(queue ++ new, MapSet.union(cooked, MapSet.new(new)), built, runtime, missing)
  end

  defp runtime_apps(nil), do: nil

  defp runtime_apps(runtime) do
    runtime.dir |> Path.join("root/lib") |> File.ls!() |> Enum.map(&String.to_atom/1)
  end

  # {required, optional}: optional_applications may be in either list.
  defp app_deps(app_file) do
    {:ok, [{:application, _, props}]} = :file.consult(app_file)
    optional = Keyword.get(props, :optional_applications, [])
    deps = Keyword.get(props, :applications, []) ++ Keyword.get(props, :included_applications, [])
    {deps -- optional, optional}
  end

  defp sys_config(nil, _env), do: "[].\n"

  defp sys_config(path, env) do
    if File.regular?(path) do
      config = Config.Reader.read!(path, env: env, target: :host)
      :io_lib.format(~c"~tp.~n", [config]) |> IO.chardata_to_string()
    else
      "[].\n"
    end
  end

  defp copy_app!(build, out, name) do
    src = Path.join(build, name)
    dst = Path.join([out, "lib", name])
    Kettlecorn.Dir.copy_tree!(Path.join(src, "ebin"), Path.join(dst, "ebin"))

    if File.dir?(Path.join(src, "priv")),
      do: Kettlecorn.Dir.copy_tree!(Path.join(src, "priv"), Path.join(dst, "priv"))
  end

  defp warn_native(out) do
    for so <- Path.wildcard(Path.join(out, "lib/*/priv/**/*.{so,dylib,dll}")) do
      IO.puts(
        :stderr,
        "kettlecorn.cook | warning: #{so} is native code, which can't be loaded in the guest"
      )
    end
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(a) when is_binary(a), do: String.to_atom(a)
end
