defmodule Kettlecorn.Install do
  @moduledoc """
  Installs the native runtime for this platform from a GitHub release.

  `runtime/1` downloads `kettlecorn-runtime-<version>-<system>.tar.gz`, or
  reads it from `:archive`, and verifies its SHA-256 against the package's
  `priv/checksums.txt`. Configure `:release_base_url` for a mirror with the
  same release layout. Downloads use the proxy in `https_proxy` or
  `HTTPS_PROXY` (`http_proxy` or `HTTP_PROXY` for an `http://` mirror),
  except for hosts in `no_proxy` or `NO_PROXY`. The archive includes the launcher; no separate
  Wasmtime installation is needed.
  """

  require Logger

  alias Kettlecorn.{Dir, Runtime}

  @release_base "https://github.com/mjrusso/kettlecorn/releases/download"
  @connect_timeout 30_000
  @timeout 600_000

  @doc "Release archive name for this platform."
  def archive_name do
    with {:ok, platform} <- Kettlecorn.Platform.current(),
         do: {:ok, "kettlecorn-runtime-#{Runtime.version()}-#{platform}.tar.gz"}
  end

  defp url(name) do
    base = Application.get_env(:kettlecorn, :release_base_url, @release_base)
    "#{base}/v#{Runtime.version()}/#{name}"
  end

  @doc """
  Installs the runtime for this package version. Set `:dir` to change the
  destination from `Kettlecorn.Runtime.installed_dir/0`. Set `:archive` to
  install from a local archive for this version and platform.

  Reuses a compatible installation unless `force: true`. Forced reinstalls
  atomically replace the destination and keep previous generations in
  `<dir>.versions` for existing readers.
  Move an invalid cache symlink aside to repair it with an ordinary install.
  Use `force: true` only at a destination you own. It authorizes overwriting
  any non-directory entry at that path, including a regular file. Move an
  existing ordinary directory aside before installing to that path.
  Returns `{:ok, dir}` or `{:error, message}`.
  """
  @spec runtime(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def runtime(opts \\ []), do: install_runtime(opts, &expected_checksum/1)

  if Mix.env() == :test do
    @doc false
    def runtime(opts, checksum), do: install_runtime(opts, checksum)
  end

  defp install_runtime(opts, checksum) do
    dir = opts[:dir] || Runtime.installed_dir()
    source = if path = opts[:archive], do: {:file, path}, else: :release

    if opts[:force] == true,
      do: install(dir, true, source, checksum),
      else: install_if_missing(dir, source, checksum)
  end

  defp install_if_missing(dir, source, checksum) do
    case Runtime.lookup_cache(dir) do
      :missing -> install(dir, false, source, checksum)
      result -> with :ok <- reuse(result, dir), do: {:ok, dir}
    end
  end

  defp reuse({:ok, _}, _dir), do: :ok

  defp reuse({:error, reason}, dir),
    do: {:error, "#{reason}. Move #{dir} aside before installing."}

  defp reuse(:missing, dir), do: {:error, "#{dir} disappeared during installation"}

  defp install(dir, force, source, checksum) do
    with {:ok, name} <- archive_name(),
         {:ok, expected} <- checksum.(name),
         {:ok, archive} <- read(source, name),
         :ok <- verify(archive, name, expected),
         :ok <- unpack_runtime(archive, dir, force) do
      {:ok, dir}
    end
  end

  defp unpack_runtime(archive, dir, force) do
    build = fn staging ->
      with :ok <- extract(archive, staging),
           {:ok, [top]} <- File.ls(staging),
           {:ok, _runtime} <- Runtime.load_release(Path.join(staging, top)) do
        {:ok, Path.join(staging, top)}
      else
        {:ok, _entries} -> {:error, "runtime archive doesn't hold one runtime directory"}
        {:error, message} -> {:error, message}
      end
    end

    if force, do: Dir.replace(dir, build), else: publish(dir, build)
  end

  defp publish(dir, build) do
    case Dir.create(dir, build) do
      :ok ->
        :ok

      :occupied ->
        dir |> Runtime.lookup_cache() |> reuse(dir)

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot publish #{dir}: #{:file.format_error(reason)}"}

      {:error, _} = error ->
        error
    end
  end

  defp extract(archive, staging) do
    case :erl_tar.extract({:binary, archive}, [:compressed, cwd: String.to_charlist(staging)]) do
      :ok -> :ok
      {:error, reason} -> {:error, "unpacking runtime archive: #{inspect(reason)}"}
    end
  end

  defp read(:release, name), do: download(url(name))

  defp read({:file, path}, _name) do
    case File.read(path) do
      {:ok, archive} -> {:ok, archive}
      {:error, reason} -> {:error, "reading #{path}: #{:file.format_error(reason)}"}
    end
  end

  # priv/checksums.txt: `sha256sum` lines, "<sha256>  <file name>".
  defp expected_checksum(name) do
    found =
      :kettlecorn
      |> :code.priv_dir()
      |> Path.join("checksums.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line) do
          [sha256, ^name] -> sha256
          _ -> nil
        end
      end)

    if found,
      do: {:ok, found},
      else:
        {:error,
         "no checksum for #{name} in priv/checksums.txt: this version of the library doesn't " <>
           "install it (for the runtime: build one with `nix build .#runtime` and set KETTLECORN_RUNTIME)"}
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    Logger.info("kettlecorn: downloading #{url}")
    get(url, cacerts(), 5)
  end

  defp cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> []
  end

  # Follows redirects itself, choosing the proxy and its credentials for each URL.
  defp get(url, cacerts, redirects) do
    with {:ok, uri} <- download_uri(url),
         :ok <- check_cacerts(uri, cacerts),
         {:ok, response} <- request(uri, cacerts) do
      handle(response, uri, cacerts, redirects)
    else
      {:error, reason} when is_binary(reason) -> {:error, "downloading #{url}: #{reason}"}
      {:error, reason} -> {:error, "downloading #{url}: #{inspect(reason)}"}
    end
  end

  defp handle({200, _headers, body}, _uri, _cacerts, _redirects), do: {:ok, body}

  defp handle({status, headers, _body}, uri, cacerts, redirects)
       when status in [301, 302, 303, 307, 308] and redirects > 0 do
    # Parsed strictly before merging: URI.merge/2 parses a string leniently.
    with {_, location} <- List.keyfind(headers, "location", 0),
         {:ok, reference} <- URI.new(location) do
      get(to_string(URI.merge(uri, reference)), cacerts, redirects - 1)
    else
      nil -> {:error, "downloading #{uri}: HTTP #{status} without a location"}
      {:error, _part} -> {:error, "downloading #{uri}: invalid redirect location"}
    end
  end

  defp handle({status, _headers, _body}, uri, _cacerts, _redirects),
    do: {:error, "downloading #{uri}: HTTP #{status}"}

  defp check_cacerts(%URI{scheme: "https"}, []),
    do:
      {:error,
       "no CA certificates found on this host; install them, " <>
         "or install from a downloaded archive with --archive"}

  defp check_cacerts(_uri, _cacerts), do: :ok

  defp request(uri, cacerts) do
    scheme = if uri.scheme == "http", do: :http, else: :https

    with {:ok, proxy} <- route(uri) do
      tls = if scheme == :https, do: [cacerts: cacerts], else: []

      options =
        [mode: :passive, protocols: [:http1], transport_opts: [timeout: @connect_timeout] ++ tls] ++
          proxy

      deadline = System.monotonic_time(:millisecond) + @timeout

      with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, uri.port, options) do
        try do
          path = URI.to_string(%URI{path: uri.path || "/", query: uri.query})

          with {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], nil),
               do: receive_response(conn, ref, deadline, {nil, [], []})
        after
          Mint.HTTP.close(conn)
        end
      end
    end
    |> case do
      {:error, %_{} = error} -> {:error, Exception.message(error)}
      {:error, _conn, error} -> {:error, Exception.message(error)}
      result -> result
    end
  end

  defp download_uri(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port} = uri}
      when scheme in ["http", "https"] and host not in [nil, ""] and port in 1..65_535 ->
        {:ok, uri}

      _ ->
        {:error, "not an http:// or https:// URL with a host"}
    end
  end

  defp receive_response(conn, ref, deadline, response) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      {:error, "the download timed out"}
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, responses} ->
          responses
          |> Enum.reduce_while(response, &collect(&1, &2, ref))
          |> continue(conn, ref, deadline)

        {:error, _conn, error, _responses} ->
          {:error, error}
      end
    end
  end

  # A status starts a response: informational responses come before the final one.
  defp collect({:status, ref, status}, {_status, _headers, body}, ref),
    do: {:cont, {status, [], body}}

  defp collect({:headers, ref, more}, {status, headers, body}, ref),
    do: {:cont, {status, headers ++ more, body}}

  defp collect({:data, ref, data}, {status, headers, body}, ref),
    do: {:cont, {status, headers, [data | body]}}

  defp collect({:done, ref}, response, ref), do: {:halt, {:done, response}}
  defp collect({:error, ref, error}, _response, ref), do: {:halt, {:error, error}}

  defp continue({:done, {status, headers, body}}, _conn, _ref, _deadline),
    do: {:ok, {status, headers, body |> Enum.reverse() |> IO.iodata_to_binary()}}

  defp continue({:error, error}, _conn, _ref, _deadline), do: {:error, error}

  defp continue(response, conn, ref, deadline),
    do: receive_response(conn, ref, deadline, response)

  defp route(%URI{scheme: scheme, host: host}) do
    name = if scheme == "http", do: "http_proxy", else: "https_proxy"

    case env(name) do
      nil ->
        {:ok, []}

      {variable, proxy} ->
        if direct?(host |> String.downcase() |> String.trim_trailing(".")),
          do: {:ok, []},
          else: proxy_route(variable, proxy)
    end
  end

  # Errors name the variable, never its value, which can hold credentials.
  defp proxy_route(variable, proxy) do
    invalid = &{:error, "invalid HTTP proxy in #{variable}: #{&1}"}

    case URI.new(if String.contains?(proxy, "://"), do: proxy, else: "http://" <> proxy) do
      {:ok, %URI{scheme: "http", host: host, port: port} = uri}
      when host not in [nil, ""] and port in 1..65_535 ->
        {:ok, [proxy: {:http, host, port, []}, proxy_headers: proxy_auth(uri.userinfo)]}

      {:ok, %URI{scheme: "http"}} ->
        invalid.("bad host or port")

      {:ok, _uri} ->
        invalid.("only http:// proxies are supported")

      # URI.new/1's reason quotes the value, which can hold credentials.
      {:error, _reason} ->
        invalid.("bad host or port")
    end
  end

  defp env(name) do
    Enum.find_value([name, String.upcase(name)], fn variable ->
      case String.trim(System.get_env(variable, "")) do
        "" -> nil
        value -> {variable, value}
      end
    end)
  end

  # Match on label boundaries so a domain entry covers only its own subdomains.
  defp direct?(host) do
    loopback =
      host == "localhost" or String.ends_with?(host, ".localhost") or
        loopback_address?(host |> String.trim_leading("[") |> String.trim_trailing("]"))

    {_variable, no_proxy} = env("no_proxy") || {"no_proxy", ""}

    entries =
      for entry <- String.split(no_proxy, ","),
          entry = entry |> String.trim() |> String.trim_leading("*.") |> String.trim_leading("."),
          entry = String.trim_trailing(entry, "."),
          entry != "",
          do: String.downcase(entry)

    loopback or "*" in entries or
      Enum.any?(entries, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  defp loopback_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, _low}} -> div(high, 256) == 127
      _ -> false
    end
  end

  defp proxy_auth(nil), do: []

  # Split before decoding, so an encoded colon stays in its part.
  defp proxy_auth(userinfo) do
    [user, password] =
      case String.split(userinfo, ":", parts: 2) do
        [user, password] -> [user, password]
        [user] -> [user, ""]
      end

    credentials = Base.encode64(URI.decode(user) <> ":" <> URI.decode(password))
    [{"proxy-authorization", "Basic " <> credentials}]
  end

  defp verify(archive, name, expected) do
    actual = :sha256 |> :crypto.hash(archive) |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "#{name}: SHA-256 #{actual}, expected #{expected}"}
  end
end
