alias Kettlecorn.{Install, Runtime}

archive = System.fetch_env!("KETTLECORN_TEST_RUNTIME_ARCHIVE") |> File.read!()
checksum = :sha256 |> :crypto.hash(archive) |> Base.encode16(case: :lower)
fetch = fn _name -> {:ok, archive, checksum} end
dir = Runtime.installed_dir()

case System.argv() do
  ["publish"] ->
    {:ok, ^dir} = Install.runtime([], fetch)

  ["find"] ->
    {:ok, original} = Runtime.find([])
    parent = System.fetch_env!("KETTLECORN_TEST_CACHE_PARENT")
    replacement = parent <> ".replacement"
    new_entry = Path.join(replacement, Path.relative_to(dir, parent))
    {:ok, ^new_entry} = Install.runtime([dir: new_entry], fetch)

    pointer = parent <> ".next"
    File.ln_s!(replacement, pointer)
    File.rename!(pointer, parent)

    {:ok, latest} = Runtime.find([])
    true = latest.dir != original.dir
    ^original = Runtime.load!(original.dir)
end
