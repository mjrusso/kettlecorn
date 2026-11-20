defmodule Mix.Tasks.Kettlecorn.Install do
  @shortdoc "Downloads the Kettlecorn runtime that matches this library"
  @moduledoc """
  Downloads and verifies the platform-specific runtime for this library version,
  including its native launcher. Python and a separate Wasmtime installation
  are not required.

      mix kettlecorn.install
      mix kettlecorn.install --force
      mix kettlecorn.install --dir runtime/

  `--dir` chooses the destination. By default, installation creates a symlink
  only if the destination is absent and reuses a compatible runtime already there.
  If the cache symlink is broken or points to an invalid runtime, move it aside
  and retry, or use `--force` if you own the destination.

  `--force` downloads the runtime again and can atomically replace any
  non-directory entry at the destination, including a regular file.
  Previous generations remain available to existing readers. Move an existing
  ordinary directory aside before installing.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [force: :boolean, dir: :string])

    case Kettlecorn.Install.runtime(opts) do
      {:ok, dir} ->
        manifest = Kettlecorn.Runtime.load!(dir).manifest

        Mix.shell().info(
          "Kettlecorn runtime #{manifest.kettlecorn} (OTP #{manifest.otp}, " <>
            "Elixir #{manifest.elixir}) in #{dir}"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
