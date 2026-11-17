defmodule Mix.Tasks.Kettlecorn.Install do
  @shortdoc "Downloads the Kettlecorn runtime that matches this library"
  @moduledoc """
  Downloads and verifies the platform-specific runtime for this library version,
  including its native launcher. Python and a separate Wasmtime installation
  are not required.

      mix kettlecorn.install
      mix kettlecorn.install --force
      mix kettlecorn.install --dir runtime/

  Installation atomically replaces a publication link; previous generations
  remain available to readers that already resolved them.
  `--dir` chooses the output path; `--force` downloads again even if a compatible
  runtime is installed. Move an existing ordinary directory aside before
  replacing it, even with `--force`.
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
