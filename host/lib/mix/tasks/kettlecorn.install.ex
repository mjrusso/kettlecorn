defmodule Mix.Tasks.Kettlecorn.Install do
  @shortdoc "Installs the Kettlecorn runtime that matches this library"
  @moduledoc """
  Installs the platform-specific runtime for this library version, including
  its native launcher. The default source is the published release archive.

      mix kettlecorn.install
      mix kettlecorn.install --force
      mix kettlecorn.install --dir runtime/
      mix kettlecorn.install --archive 'kettlecorn-runtime-<version>-<system>.tar.gz'

  Use `--archive PATH` to install from a local file. The archive must match
  the platform and library version. The installer verifies it against the
  bundled checksum.

  `--dir` chooses the destination. By default, installation creates a symlink
  only if the destination is absent and reuses a compatible runtime already there.
  If the cache symlink is broken or points to an invalid runtime, move it aside
  and retry, or use `--force` if you own the destination.

  `--force` installs the runtime again and can atomically replace any
  non-directory entry at the destination, including a regular file.
  Previous generations remain available to existing readers. Move an existing
  ordinary directory aside before installing.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [force: :boolean, dir: :string, archive: :string])

    if rest != [],
      do:
        Mix.raise("unexpected arguments #{inspect(rest)}; use --archive PATH for a local archive")

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
