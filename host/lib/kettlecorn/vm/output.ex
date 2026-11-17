defmodule Kettlecorn.VM.Output do
  @moduledoc false

  # Must agree with OUTPUT_PACKET_BYTES in launcher/src/fd.rs.
  @packet_bytes 65_536

  @enforce_keys [:dir]
  defstruct [:dir, :socket]

  def prepare! do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    name = "kc-output-" <> suffix
    directory = Path.join(System.tmp_dir!(), name)
    # macOS limits Unix socket paths to 103 bytes, regardless of instances_dir.
    dir =
      if byte_size(Path.join(directory, "out")) <= 103,
        do: directory,
        else: Path.join("/tmp", name)

    File.mkdir!(dir)

    try do
      File.chmod!(dir, 0o700)
      %__MODULE__{dir: dir}
    rescue
      error ->
        File.rmdir(dir)
        reraise error, __STACKTRACE__
    end
  end

  def path(output), do: Path.join(output.dir, "out")

  def connect(output) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path(output)},
             0,
             [:binary, packet: 4, packet_size: @packet_bytes, active: :once],
             5_000
           ) do
      {:ok, %{output | socket: socket}}
    end
  end

  def next(output), do: :inet.setopts(output.socket, active: :once)

  def cleanup(output) do
    if output.socket, do: :gen_tcp.close(output.socket)
    File.rm_rf(output.dir)
    :ok
  end
end
