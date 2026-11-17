defmodule Kettlecorn.DirTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Dir

  @moduletag :tmp_dir

  defp build(content) do
    fn staging ->
      out = Path.join(staging, "out")
      File.mkdir_p!(out)
      File.write!(Path.join(out, "file"), content)
      {:ok, out}
    end
  end

  test "replaces a directory given with a trailing slash, retaining published generations",
       %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest") <> "/"
    assert :ok = Dir.replace(dir, build("one"))
    assert {:ok, original} = Dir.resolve(dir)
    assert :ok = Dir.replace(dir, build("two"))
    assert File.read!(Path.join(original, "file")) == "one"
    assert File.read!(Path.join(dir, "file")) == "two"
  end

  test "a failed build keeps the previous directory", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest")
    assert :ok = Dir.replace(dir, build("one"))
    assert {:error, "no"} = Dir.replace(dir, fn _staging -> {:error, "no"} end)
    assert File.read!(Path.join(dir, "file")) == "one"
  end

  test "nested publications relocate and can be exported by dereferencing", %{tmp_dir: tmp} do
    project = Path.join(tmp, "project")
    dir = Path.join(project, "runtime")

    assert :ok =
             Dir.replace(dir, fn staging ->
               out = Path.join(staging, "out")
               :ok = Dir.replace(Path.join(out, "wasmtime"), build("engine"))
               {:ok, out}
             end)

    moved = Path.join(tmp, "moved")
    File.rename!(project, moved)
    runtime = Path.join(moved, "runtime")
    assert File.read!(Path.join(runtime, "wasmtime/file")) == "engine"

    exported = Path.join(tmp, "exported")
    Dir.copy_tree!(runtime, exported)
    File.rm_rf!(moved)
    assert File.read!(Path.join(exported, "wasmtime/file")) == "engine"
    assert {:ok, %{type: :directory}} = File.lstat(Path.join(exported, "wasmtime"))
  end

  test "concurrent publications expose only complete generations", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest")
    assert :ok = Dir.replace(dir, build("initial"))

    reader =
      Task.async(fn ->
        for _ <- 1..200 do
          assert {:ok, snapshot} = Dir.resolve(dir)
          assert {:ok, content} = File.read(Path.join(snapshot, "file"))
          assert content in ["initial", "one", "two"]
        end
      end)

    publishers =
      for value <- ["one", "two"], do: Task.async(fn -> Dir.replace(dir, build(value)) end)

    for publisher <- publishers, do: assert(Task.await(publisher) == :ok)
    Task.await(reader)
  end

  test "refuses to replace an unmanaged directory", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest")
    File.mkdir!(dir)
    File.write!(Path.join(dir, "file"), "original")
    assert {:error, _} = Dir.replace(dir, build("replacement"))
    assert File.read!(Path.join(dir, "file")) == "original"
  end
end
