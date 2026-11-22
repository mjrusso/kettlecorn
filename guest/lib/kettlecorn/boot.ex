defmodule Kettlecorn.Boot do
  @moduledoc false
  # Both launchers use this boot sequence: cooked code paths and
  # configuration, preload if requested, guest app, extra apps, cooked
  # entrypoint, then boot_ready.

  alias Kettlecorn.Event
  alias Kettlecorn.Preload

  @cooked_app "/app/app"
  @cooked_config ~c"/app/sys.config"
  @cooked_libs "/app/lib/*/ebin"

  @doc false
  def network_granted?, do: :init.get_argument(:kettlecorn_network) != :error

  def start do
    # https://github.com/erlang/otp/issues/12119: loading these lazily from
    # inside an evaluation can deadlock the code server.
    for module <- [:eval_bits, :records], do: :code.ensure_loaded(module)

    apps =
      case :init.get_argument(:kettlecorn_apps) do
        {:ok, [apps]} -> Enum.map(apps, &List.to_atom/1)
        :error -> []
      end

    apps = [:kettlecorn_guest | apps]

    with :ok <- load_cacerts(),
         {:ok, entrypoint} <- cooked_app(),
         :ok <- Preload.run(Preload.mode()),
         nil <- Enum.find_value(apps ++ entrypoint, &start_failure/1) do
      Event.send(%{event: :boot_ready, embedded_api: 1})
    else
      {step, reason} ->
        :io.format(:standard_error, "kettlecorn: ~ts failed: ~tp~n", [step, reason])
        Event.send(%{event: :boot_failed})
        :erlang.halt(1)
    end
  end

  # OTP cannot discover CA certificates on WASI.
  defp load_cacerts do
    path = System.get_env("KETTLECORN_CACERTFILE")

    if path && File.regular?(path) do
      case :public_key.cacerts_load(path) do
        :ok -> :ok
        {:error, reason} -> {"loading CA certificates from #{path}", reason}
      end
    else
      :ok
    end
  end

  defp cooked_app do
    case File.read(@cooked_app) do
      {:ok, name} ->
        with :ok <- compatible_bundle(), do: prepare_app(name)

      {:error, :enoent} ->
        {:ok, []}

      error ->
        {"reading /app/app", error}
    end
  end

  defp prepare_app(name) do
    # Add cooked paths before starting apps so their versions take precedence.
    @cooked_libs |> Path.wildcard() |> Enum.map(&String.to_charlist/1) |> :code.add_pathsa()
    load_config(String.to_atom(String.trim(name)))
  end

  defp compatible_bundle do
    with {:ok, runtime} <- File.read("/manifest.json"),
         {:ok, runtime} <- JSON.decode(runtime),
         {:ok, bundle} <- File.read("/app/kettlecorn.json"),
         {:ok, bundle} <- JSON.decode(bundle),
         expected = %{
           "protocol" => runtime["protocol"],
           "elixir" => System.version(),
           "otp" => System.otp_release()
         },
         true <- bundle == expected do
      :ok
    else
      _ -> {"checking /app/kettlecorn.json", "incompatible cooked application"}
    end
  end

  defp load_config(entrypoint) do
    case :file.consult(@cooked_config) do
      {:ok, [config]} ->
        # Preserve these values when application loading reads defaults from .app files.
        Application.put_all_env(config, persistent: true)
        {:ok, [entrypoint]}

      error ->
        {"reading /app/sys.config", error}
    end
  end

  def cli do
    start()
    if Preload.mode() != :off, do: last_exit_hook()
    :elixir.start_cli()
    :erlang.halt()
  end

  # Kernel.CLI runs exit hooks newest first. Append this hook so earlier
  # hooks can still trigger late-load reports before we flush them.
  defp last_exit_hook,
    do: :elixir_config.update(:at_exit, fn hooks -> List.insert_at(hooks, -1, &exit_hook/1) end)

  # Hooks registered during this batch run in the next one. Wait until
  # they finish before flushing the reporter and halting.
  defp exit_hook(status) do
    case :elixir_config.get(:at_exit) do
      [] ->
        if Code.loaded?(Logger), do: Logger.flush()
        Preload.flush()
        System.halt(status)

      _ ->
        last_exit_hook()
    end
  end

  defp start_failure(app) do
    case :application.ensure_all_started(app) do
      {:ok, _apps} -> nil
      {:error, reason} -> {"starting #{app}", reason}
    end
  end
end
