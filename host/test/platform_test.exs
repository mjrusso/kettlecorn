defmodule Kettlecorn.PlatformTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Platform

  test "selects supported native runtime archives" do
    assert Platform.target("x86_64-pc-linux-gnu", {:unix, :linux}) == {:ok, "x86_64-linux"}
    assert Platform.target("aarch64-unknown-linux-gnu", {:unix, :linux}) == {:ok, "aarch64-linux"}
    assert Platform.target("aarch64-apple-darwin23", {:unix, :darwin}) == {:ok, "aarch64-darwin"}
    assert {:error, _} = Platform.target("x86_64-apple-darwin", {:unix, :darwin})
    assert {:error, _} = Platform.target("riscv64-linux", {:unix, :linux})
    assert {:error, _} = Platform.target("win32", {:win32, :nt})
    assert {:ok, archive} = Kettlecorn.Install.archive_name()
    assert archive =~ "kettlecorn-runtime-#{Kettlecorn.Runtime.version()}-"
  end
end
