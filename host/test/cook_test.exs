defmodule Kettlecorn.CookTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Cook

  @moduletag :tmp_dir

  # A fake _build/prod/lib: an app, a dependency with priv/, and
  # applications the app doesn't depend on (hex, the host library, a
  # plugin); and a config file.
  defp fake_build(tmp) do
    build = Path.join(tmp, "build")

    app = fn name, deps, optional ->
      ebin = Path.join([build, name, "ebin"])
      File.mkdir_p!(ebin)

      props = [
        applications: [:kernel, :stdlib | deps],
        optional_applications: optional,
        vsn: ~c"0.1.0"
      ]

      File.write!(
        Path.join(ebin, "#{name}.app"),
        :io_lib.format(~c"~p.~n", [{:application, String.to_atom(name), props}])
      )

      File.write!(Path.join(ebin, "Elixir.#{Macro.camelize(name)}.beam"), "beam")
    end

    # :opt is optional, and in neither the build nor the runtime.
    app.("my_app", [:dep_a, :opt], [:opt])
    app.("dep_a", [], [])
    app.("hex", [:inets], [])
    app.("kettlecorn", [], [])
    app.("plugin", [:dep_a, :inets], [])
    File.mkdir_p!(Path.join([build, "dep_a", "priv"]))
    File.write!(Path.join([build, "dep_a", "priv", "data.txt"]), "data")

    config = Path.join(tmp, "config.exs")
    File.write!(config, ~s|import Config\nconfig :my_app, answer: 42, env: config_env()\n|)
    {build, config}
  end

  test "cooks an app with its dependencies, priv files and config", %{tmp_dir: tmp} do
    {build, config} = fake_build(tmp)
    out = Path.join(tmp, "out")

    assert {:ok, %{app: :my_app, apps: [:dep_a, :my_app]}} =
             Cook.cook(app: "my_app", build: build, out: out, config: config, env: :prod)

    assert File.read!(Path.join(out, "app")) == "my_app"
    assert File.read!(Path.join(out, "lib/dep_a/priv/data.txt")) == "data"
    assert File.exists?(Path.join(out, "lib/my_app/ebin/my_app.app"))
    assert out |> Path.join("lib") |> File.ls!() |> Enum.sort() == ["dep_a", "my_app"]

    assert {:ok, [[my_app: [answer: 42, env: :prod]]]} =
             :file.consult(Path.join(out, "sys.config"))
  end

  test "a failed cook leaves the previous output as it was", %{tmp_dir: tmp} do
    {build, config} = fake_build(tmp)
    out = Path.join(tmp, "out")
    assert {:ok, _} = Cook.cook(app: :my_app, build: build, out: out, config: config)

    File.write!(config, ~s|import Config\nraise "bad config"\n|)

    assert_raise RuntimeError, "bad config", fn ->
      Cook.cook(app: :my_app, build: build, out: out, config: config)
    end

    assert {:ok, [[my_app: [answer: 42, env: :prod]]]} =
             :file.consult(Path.join(out, "sys.config"))
  end

  test "cooks the roots with their dependencies, and reports those the guest doesn't have",
       %{tmp_dir: tmp} do
    {build, _config} = fake_build(tmp)
    runtime = TestRuntime.fixture(Path.join(tmp, "runtime"))

    assert {:ok, %{apps: [:dep_a, :my_app]}} =
             Cook.cook(app: :my_app, build: build, out: Path.join(tmp, "a"), runtime: runtime)

    assert {:error, message} =
             Cook.cook(
               app: :my_app,
               roots: [:plugin],
               build: build,
               out: Path.join(tmp, "b"),
               runtime: runtime
             )

    assert message == "applications not available in the guest: inets (needed by plugin)"

    File.mkdir_p!(Path.join([runtime, "root/lib/inets"]))

    assert {:ok, %{apps: [:dep_a, :my_app, :plugin]}} =
             Cook.cook(
               app: :my_app,
               roots: ["plugin"],
               build: build,
               out: Path.join(tmp, "c"),
               runtime: runtime
             )
  end

  test "fails for an unknown entrypoint", %{tmp_dir: tmp} do
    {build, _} = fake_build(tmp)
    assert {:error, message} = Cook.cook(app: :nope, build: build, out: Path.join(tmp, "out"))
    assert message =~ "not in the build: nope"
  end

  test "startup rejects cooked metadata for another compiler or protocol", %{tmp_dir: tmp} do
    {build, _} = fake_build(tmp)
    runtime = TestRuntime.fixture(Path.join(tmp, "runtime"))
    out = Path.join(tmp, "out")
    assert {:ok, _} = Cook.cook(app: :my_app, build: build, out: out, runtime: runtime)

    for {key, value} <- [{"protocol", -1}, {"otp", "0"}, {"elixir", "0.0.0"}, {"extra", true}] do
      fields = Map.put(Kettlecorn.Bundle.compiler(), key, value)
      File.write!(Path.join(out, "kettlecorn.json"), JSON.encode!(fields))

      assert_raise ArgumentError, ~r/not a compatible cooked application/, fn ->
        Kettlecorn.Sandbox.new(runtime: runtime, app: out)
      end
    end
  end

  test "rejects an incompatible runtime before publication", %{tmp_dir: tmp} do
    {build, _} = fake_build(tmp)
    runtime = Path.join(tmp, "runtime")
    TestRuntime.fixture(runtime, %{"elixir" => "0.0.0"})
    out = Path.join(tmp, "out")
    assert {:error, message} = Cook.cook(app: :my_app, build: build, out: out, runtime: runtime)
    assert message =~ "compiler must match"
    refute File.exists?(out)
  end

  test "the task checks the installed runtime by default, and says when there is none",
       %{tmp_dir: tmp} do
    mix = fn home, args ->
      System.cmd("mix", args,
        cd: Path.expand("..", __DIR__),
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"HOME", home},
          {"XDG_CACHE_HOME", nil},
          {"KETTLECORN_RUNTIME", nil},
          {"ERL_FLAGS", "+S 2:2"}
        ]
      )
    end

    path_file = Path.join(tmp, "installed-dir")
    probe = "File.write!(#{inspect(path_file)}, Kettlecorn.Runtime.installed_dir())"
    {_, 0} = mix.(tmp, ["run", "--no-compile", "--no-start", "-e", probe])

    relative_cache = Path.relative_to(File.read!(path_file), tmp)
    assert Path.type(relative_cache) == :relative

    out = Path.join(tmp, "out")
    version = Kettlecorn.Runtime.version()

    home = Path.join(tmp, "compiler")

    TestRuntime.fixture(Path.join(home, relative_cache), %{
      "kettlecorn" => version,
      "elixir" => "0.0.0"
    })

    {output, status} = mix.(home, ["kettlecorn.cook", "--out", out])
    assert status != 0, output
    assert output =~ "compiler must match"
    refute File.exists?(out)

    {output, 0} = mix.(Path.join(tmp, "empty"), ["kettlecorn.cook", "--out", out])
    assert output =~ "No runtime found; skipping the compatibility check"
  end
end
