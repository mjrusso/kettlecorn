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

  defp stage_publications(dir, contents) do
    parent = self()

    publishers =
      for content <- contents do
        Task.async(Dir, :replace, [dir, staged_build(content, parent)])
      end

    for %{pid: pid, ref: ref} <- publishers do
      receive do
        {:staged, ^pid} -> :ok
        {^ref, result} -> flunk("publication returned before staging: #{inspect(result)}")
      end
    end

    publishers
  end

  defp staged_build(content, parent) do
    fn staging ->
      built = build(content).(staging)
      send(parent, {:staged, self()})

      receive do
        :publish -> built
      end
    end
  end

  defp publish(publishers) do
    for %{pid: pid} <- publishers, do: send(pid, :publish)
    for publisher <- publishers, do: assert(Task.await(publisher, :infinity) == :ok)
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

  test "resolves parent symlinks before going up a directory in a link target", %{tmp_dir: tmp} do
    {:ok, tmp} = Dir.resolve(tmp)
    base = Path.join(tmp, "tree")
    File.mkdir_p!(Path.join(base, "child"))
    runtime = Path.join(base, "runtime")
    File.mkdir!(runtime)
    File.ln_s!("tree/child", Path.join(tmp, "alias"))
    publication = Path.join(tmp, "publication")
    File.ln_s!("alias/../runtime", publication)

    assert {:ok, ^runtime} = Dir.resolve(publication)
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
    publishers = stage_publications(dir, ["one", "two"])

    assert {:ok, original} = Dir.resolve(dir)
    assert File.read!(Path.join(original, "file")) == "initial"

    publish(publishers)

    assert {:ok, latest} = Dir.resolve(dir)
    assert File.read!(Path.join(latest, "file")) in ["one", "two"]
    assert File.read!(Path.join(original, "file")) == "initial"
  end

  test "concurrent publications both succeed at an empty destination", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest")
    dir |> stage_publications(["one", "two"]) |> publish()

    generations = dir <> ".versions"

    assert Enum.sort(
             for generation <- File.ls!(generations),
                 do: File.read!(Path.join([generations, generation, "file"]))
           ) == ["one", "two"]

    assert File.read!(Path.join(dir, "file")) in ["one", "two"]
  end

  test "refuses to replace an unmanaged directory", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "dest")
    File.mkdir!(dir)
    File.write!(Path.join(dir, "file"), "original")
    assert {:error, _} = Dir.replace(dir, build("replacement"))
    assert File.read!(Path.join(dir, "file")) == "original"
    assert File.ls!(dir <> ".versions") == []
  end

  test "atomic replacement can overwrite an existing file at a caller-owned path", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "runtime")
    File.write!(dir, "original")

    assert :ok = Dir.replace(dir, build("replacement"))
    assert {:ok, %{type: :symlink}} = File.lstat(dir)
    assert File.read!(Path.join(dir, "file")) == "replacement"
  end

  test "create reports the winning generation and cleans up the losing build", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "runtime")

    late_build = fn staging ->
      built = build("late").(staging)
      assert :ok = Dir.create(dir, build("winner"))
      built
    end

    assert :occupied = Dir.create(dir, late_build)
    assert File.read!(Path.join(dir, "file")) == "winner"
    assert [_winner] = File.ls!(dir <> ".versions")
  end

  test "remove_tree removes a tree, and logs what it can't remove", %{tmp_dir: tmp} do
    tree = Path.join(tmp, "tree")
    File.mkdir_p!(Path.join(tree, "a/b"))
    File.write!(Path.join(tree, "a/b/file"), "x")
    File.chmod!(Path.join(tree, "a/b/file"), 0o444)
    assert Dir.remove_tree(tree) == :ok
    refute File.exists?(tree)

    locked = Path.join(tmp, "locked")
    kept = Path.join(locked, "kept")
    File.mkdir_p!(kept)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)
    # A privileged runner can delete in a read-only directory.
    denied = File.mkdir(Path.join(locked, "probe")) == {:error, :eacces}

    log = ExUnit.CaptureLog.capture_log(fn -> assert Dir.remove_tree(kept) == :ok end)

    if denied do
      assert log =~ ~r/cannot clean up #{Regex.escape(kept)}: rm exited with \d+: .+/
      assert File.dir?(kept)
    end
  end

  test "a staging collision is returned as a build error", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "runtime")
    assert {:error, :eexist} = Dir.create(dir, fn _staging -> {:error, :eexist} end)
    assert {:error, :enoent} = File.lstat(dir)
  end

  test "create preserves a regular file written while staging", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "runtime")

    assert :occupied =
             Dir.create(dir, fn staging ->
               staged = build("runtime").(staging)
               File.write!(dir, "original")
               staged
             end)

    assert {:ok, %{type: :regular}} = File.lstat(dir)
    assert File.read!(dir) == "original"
    assert File.ls!(dir <> ".versions") == []
  end
end
