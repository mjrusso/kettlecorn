defmodule Kettlecorn.HTTP do
  @moduledoc """
  Outgoing HTTP from the guest, over `wasi:http/client`.

  Requires the HTTP grant (`Kettlecorn.start_link(http: true)` or
  `kettlecorn-run --http`), which runs `beam-http.wasm` and enables HTTP
  interfaces in the embedded engine. The guest then sets
  `Kettlecorn.HTTP.ReqAdapter` as Req's default adapter:

      Req.get!("https://api.example.com/status").body

  Without Req:

      {:ok, %{status: 200, headers: headers, body: body}} =
        Kettlecorn.HTTP.request(:get, "https://example.com/")

  Wasmtime handles TLS using its compiled Mozilla root CA list; the host's
  trust store and the VM's `:cacerts` option do not change it. Req handles
  redirects and response decompression.
  """

  @compile {:no_warn_undefined, :wasm}
  @connect_timeout 30_000
  @receive_timeout 15_000
  @chunk 65_536

  @type headers :: [{String.t(), String.t()}]

  @doc "Whether the VM may use HTTP."
  @spec available?() :: boolean()
  def available?, do: :wasm.http_available()

  @doc """
  Makes a request and reads the whole response:
  `{:ok, %{status: integer, headers: headers, body: binary}}` or
  `{:error, reason}` (e.g. `:unsupported` without the HTTP grant,
  `:connection_refused`, `:invalid_url`).

  Options: `:headers` (a list of `{name, value}`), `:body` (iodata),
  `:connect_timeout` (ms, default #{@connect_timeout}) and `:receive_timeout`
  (ms, default #{@receive_timeout}: the longest wait for the response head
  and for each part of the body, like Req's).

  Timeouts accept non-negative integer milliseconds, up to 18_446_744_073_709,
  or `:default`. Zero means an immediate timeout. `:infinity` returns
  `{:error, :unsupported_timeout}` because wasi:http cannot disable timeouts.
  Other values raise `ArgumentError`.
  """
  @spec request(atom() | String.t(), String.t() | URI.t(), keyword()) ::
          {:ok, %{status: non_neg_integer(), headers: headers(), body: binary()}}
          | {:error, term()}
  def request(method, url, opts \\ []) do
    fun = fn
      {:status, status}, acc -> {:cont, Map.put(acc, :status, status)}
      {:headers, headers}, acc -> {:cont, Map.put(acc, :headers, headers)}
      {:data, data}, acc -> {:cont, Map.update!(acc, :body, &[&1 | data])}
    end

    case stream(method, url, %{body: []}, fun, opts) do
      {:ok, resp} -> {:ok, %{resp | body: IO.iodata_to_binary(resp.body)}}
      {:error, reason, _acc} -> {:error, reason}
    end
  end

  @doc """
  Makes a request and streams the response through `fun`, like
  `Enum.reduce_while/3`: `fun` gets `{:status, status}`, then
  `{:headers, headers}`, then `{:data, chunk}` for each part of the body, and
  returns `{:cont, acc}` or `{:halt, acc}`. Returns `{:ok, acc}`, or
  `{:error, reason, acc}` with the accumulator as it was when the request
  failed (to clean up a partly written body, for instance). Same options as
  `request/3`.
  """
  @spec stream(atom() | String.t(), String.t() | URI.t(), acc, fun, keyword()) ::
          {:ok, acc} | {:error, term(), acc}
        when acc: term(), fun: (term(), acc -> {:cont, acc} | {:halt, acc})
  def stream(method, url, acc, fun, opts \\ []) do
    case split_url(url) do
      {:ok, scheme, authority, path} ->
        send_request(method, scheme, authority, path, acc, fun, opts)

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp send_request(method, scheme, authority, path, acc, fun, opts) do
    body = if b = opts[:body], do: IO.iodata_to_binary(b)
    headers = content_length(opts[:headers] || [], body)
    connect = Keyword.get(opts, :connect_timeout, :default)
    read = Keyword.get(opts, :receive_timeout, :default)
    method = method |> to_string() |> String.upcase()

    case :wasm.http_send(method, scheme, authority, path, headers, body, connect, read) do
      {:ok, ref, status, resp_headers} ->
        try do
          with {:cont, acc} <- fun.({:status, status}, acc),
               {:cont, acc} <- fun.({:headers, resp_headers}, acc) do
            read_body(ref, acc, fun)
          else
            {:halt, acc} -> {:ok, acc}
          end
        after
          :wasm.http_close(ref)
        end

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp read_body(ref, acc, fun) do
    case :wasm.http_read(ref, @chunk) do
      {:ok, data} ->
        case fun.({:data, data}, acc) do
          {:cont, acc} -> read_body(ref, acc, fun)
          {:halt, acc} -> {:ok, acc}
        end

      :eof ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp split_url(url) do
    uri = URI.parse(url)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host do
      # An IPv6 address goes in brackets, as in the URL.
      host = if String.contains?(host, ":"), do: "[#{host}]", else: host
      authority = if uri.port == URI.default_port(scheme), do: host, else: "#{host}:#{uri.port}"
      path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
      {:ok, String.to_existing_atom(scheme), authority, path}
    else
      _ -> {:error, :invalid_url}
    end
  end

  # The body is complete: send its length instead of letting wasi:http fall
  # back to chunked encoding, which some servers don't accept.
  defp content_length(headers, nil), do: headers

  defp content_length(headers, body) do
    if Enum.any?(headers, fn {name, _} -> String.downcase(name) == "content-length" end),
      do: headers,
      else: [{"content-length", Integer.to_string(byte_size(body))} | headers]
  end
end

if Code.ensure_loaded?(Req) do
  defmodule Kettlecorn.HTTP.ReqAdapter do
    @moduledoc """
    A Req adapter over `Kettlecorn.HTTP` (`wasi:http`). The guest installs it
    as Req's default adapter when the VM may use HTTP; otherwise Req uses
    Finch over sockets (which needs `network: true`).

    Supports Req's `:into` with a function or a collectable; not `into: :self`.
    Transport errors are `Req.TransportError` exceptions.
    Collectables receive `:done` on success and `:halt` on transport errors
    or exceptions. Exceptions propagate after cleanup.
    """

    def run(%Req.Request{} = request) do
      opts =
        [headers: headers(request), body: body(request.body)]
        |> put_timeout(
          :connect_timeout,
          Keyword.fetch(request.options[:connect_options] || [], :timeout)
        )
        |> put_timeout(:receive_timeout, Map.fetch(request.options, :receive_timeout))

      case request.into do
        nil ->
          into_collectable(request, opts, "")

        fun when is_function(fun, 2) ->
          case stream(request, opts, Req.Response.new(), fun) do
            {:ok, result} -> result
            {:error, exception, _acc} -> {request, exception}
          end

        :self ->
          raise ArgumentError, "Kettlecorn.HTTP.ReqAdapter doesn't support into: :self"

        collectable ->
          into_collectable(request, opts, collectable)
      end
    end

    defp into_collectable(request, opts, collectable) do
      {acc, collector} = Collectable.into(collectable)

      push = fn {:data, data}, {req, resp} ->
        {:cont, {req, %{resp | body: collector.(resp.body, {:cont, data})}}}
      end

      try do
        with {:ok, {req, resp}} <-
               stream(request, opts, Req.Response.new(body: acc), push) do
          {req, %{resp | body: collector.(resp.body, :done)}}
        end
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__

          # Preserve the original failure even if :halt raises.
          try do
            # Enum.into/2 also halts with the initial accumulator.
            collector.(acc, :halt)
          catch
            _, _ -> :ok
          end

          :erlang.raise(kind, reason, stacktrace)
      else
        {:error, exception, {_req, resp}} ->
          collector.(resp.body, :halt)
          {request, exception}

        response ->
          response
      end
    end

    defp stream(request, opts, response, on_data) do
      fun = fn
        {:status, status}, {req, resp} -> {:cont, {req, %{resp | status: status}}}
        {:headers, headers}, {req, resp} -> {:cont, {req, put_headers(resp, headers)}}
        {:data, _} = data, acc -> on_data.(data, acc)
      end

      case Kettlecorn.HTTP.stream(request.method, request.url, {request, response}, fun, opts) do
        {:ok, _acc} = result -> result
        {:error, reason, acc} -> {:error, %Req.TransportError{reason: reason}, acc}
      end
    end

    defp put_headers(resp, headers),
      do: %{resp | headers: Req.Response.new(headers: headers).headers}

    defp headers(request) do
      for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
    end

    defp body(nil), do: nil
    defp body(body) when is_binary(body) or is_list(body), do: body
    defp body(enumerable), do: Enum.into(enumerable, [])

    defp put_timeout(opts, key, {:ok, timeout}),
      do: Keyword.put(opts, key, timeout)

    defp put_timeout(opts, _key, :error), do: opts
  end
end
