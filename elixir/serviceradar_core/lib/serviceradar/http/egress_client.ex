defmodule ServiceRadar.HTTP.EgressClient do
  @moduledoc """
  HTTPS GET for hosts outside the deployment, over `SERVICERADAR_EGRESS_PROXY`.

  Every fetch of an external host belongs here -- `download_to_file/3` for
  artifacts and databases, `fetch_body/2` for API and dataset responses. The
  shared `ServiceRadar.Finch` pool connects directly and never uses the proxy,
  so a request on it to an external host bypasses the egress allowlist and is
  refused wherever a default-deny NetworkPolicy admits only the proxy.

  Uses OTP's `:httpc` instead of `Req` + `ServiceRadar.Finch`, because Mint --
  Finch's transport -- cannot tunnel through the CONNECT proxy this deployment
  runs behind.

  Smokescreen embeds `elazarl/goproxy`, which answers `CONNECT` with the 19
  bytes `HTTP/1.0 200 OK\\r\\n\\r\\n` and no headers at all. Mint 1.10.0 started
  framing the CONNECT response correctly ("Fix CONNECT response framing ... in
  tunnel proxies"), so `Mint.HTTP1` now completes that response -- and a
  completed response goes through the generic rule in `Mint.HTTP1.request_done/1`:
  an HTTP/1.0 response carrying no `connection: keep-alive` closes the
  connection. Mint therefore closes the tunnel socket it is about to hand to
  `Mint.TunnelProxy.upgrade_connection/3`, which then upgrades a socket that is
  already shut.

  The error that reaches the operator names none of this. `ssl:connect/3` -- the
  socket-upgrade arity -- wraps its body in `try ... catch error:{badmatch, _}
  -> {error, {dtls_upgrade, notsup}}`, and `tls_socket:upgrade/4` opens with
  `ok = setopts(...)`. On a closed socket `setopts` returns `{error, einval}`,
  the match fails, and OTP reports the failure as `{:dtls_upgrade, :notsup}` --
  which mentions neither the proxy nor the closed socket, and is not about DTLS.

  RFC 9110 section 9.3.6 is explicit that a 2xx response to `CONNECT` establishes
  a tunnel, so HTTP/1.0 connection-close semantics must not be applied to it.
  Mint 1.9.3 left the socket open and this worked; 1.10.0 closes it. Pinning back
  is not available: 1.10.0 carries the fixes for CVE-2026-82728 and
  CVE-2026-82729. See `third_party/hex/BUILD.bazel` for the workspace dependency
  resolution policy.

  `:httpc` performs its own CONNECT and accepts the HTTP/1.0 reply, so it
  tunnels through the same proxy unchanged. Only one client is used, whether or
  not a proxy is configured, so the path exercised by tests is the path that
  runs on a proxied deployment.
  """

  alias ServiceRadar.HTTP.EgressProxy

  @default_profile :serviceradar_egress
  @default_timeout 30_000
  @tls_versions [:"tlsv1.3", :"tlsv1.2"]
  @depth 4
  @default_max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  @type option ::
          {:headers, [{binary(), binary()}]}
          | {:receive_timeout, pos_integer()}
          | {:connect_timeout, pos_integer()}
          | {:into, (term(), term() -> {:cont, term()} | {:halt, term()})}
          | {:max_bytes, pos_integer()}
          | {:proxy, EgressProxy.t() | nil}
          | {:profile, atom()}
          | {:cacerts, [binary()]}
          | {:cacertfile, String.t()}
          | {:max_redirects, non_neg_integer()}

  @doc """
  Fetches `url` with GET.

  Redirects are never followed: the caller decides, the same way
  `Req.get(redirect: false)` behaves. The required `:into` option takes a
  streaming function called as `fun.({:data, chunk}, acc)` that returns
  `{:cont, acc}`, `{:halt, acc}`, or `{:error, reason}`. Its initial accumulator is
  `{nil, Req.Response.new(status: 200)}`. Each next chunk is requested only after
  the callback consumes the previous one. Streamed responses return an empty
  body; the callback owns the downloaded bytes, and its accumulator is not
  returned. Halting cancels the request and returns an empty successful response.
  A callback error cancels the request and returns `{:error, reason}` to the caller.

  `:receive_timeout` bounds each wait for headers or the next chunk, not the
  total transfer or callback execution time. It defaults to 30,000 milliseconds;
  `:connect_timeout` defaults to the configured `:receive_timeout`. `:max_bytes`, when supplied,
  rejects a streamed chunk that would exceed the limit before calling `:into`.
  OTP streams only 200/206 bodies; other statuses arrive buffered and their size
  is checked afterward. Streamed responses are reported as status 200, so this
  interface is intended for full artifact downloads without Range requests.

  Options that exist only for `Req` call-site parity (`:decode_body`,
  `:redirect`, `:max_redirects`, `:finch`, `:retry`) are accepted and ignored
  here. `download_to_file/3` and `fetch_body/2` follow redirects and honor
  `:max_redirects`.
  """
  @spec get(String.t(), [option()]) :: {:ok, Req.Response.t()} | {:error, term()}
  def get(url, opts \\ []) when is_binary(url) do
    into = Keyword.fetch!(opts, :into)
    true = is_function(into, 2)
    profile = Keyword.get(opts, :profile, @default_profile)

    with {:ok, profile} <- ensure_profile(profile),
         :ok <- configure_proxy(profile, opts) do
      request(url, opts, profile)
    end
  end

  @doc """
  Streams `url` into `dest_path`, following redirects.

  The body lands in `dest_path <> ".tmp"` and is renamed into place only after a
  complete 200, so a failed or partial transfer never replaces a good file and
  leaves no temporary behind. A final status other than 200 is
  `{:error, {:http_status, status}}`.

  Takes the options of `get/2` except `:into`, plus `:max_redirects` (default
  #{@default_max_redirects}). Only HTTPS redirect targets are followed.
  """
  @spec download_to_file(String.t(), Path.t(), [option()]) :: {:ok, Path.t()} | {:error, term()}
  def download_to_file(url, dest_path, opts \\ []) when is_binary(url) and is_binary(dest_path) do
    tmp = dest_path <> ".tmp"
    _ = File.rm(tmp)

    result =
      case File.open(tmp, [:write, :binary], fn file ->
             get_following(url, Keyword.put(opts, :into, write_into(file)))
           end) do
        {:ok, result} -> result
        {:error, _} = error -> error
      end

    case result do
      {:ok, %Req.Response{status: 200}} ->
        promote(tmp, dest_path)

      {:ok, %Req.Response{status: status}} ->
        _ = File.rm(tmp)
        {:error, {:http_status, status}}

      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @doc """
  GETs `url` and returns the whole body in the response, following redirects.

  For API and dataset responses small enough to hold in memory; pass
  `:max_bytes` to bound them. The response comes back whatever its status, as
  with `Req.get/2`: judging a non-2xx is the caller's business. The body is the
  raw binary; nothing is decoded.

  Takes the options of `get/2` except `:into`, plus `:max_redirects` (default
  #{@default_max_redirects}). Only HTTPS redirect targets are followed.
  """
  @spec fetch_body(String.t(), [option()]) :: {:ok, Req.Response.t()} | {:error, term()}
  def fetch_body(url, opts \\ []) when is_binary(url) do
    ref = make_ref()
    parent = self()

    into = fn {:data, chunk}, acc ->
      send(parent, {ref, chunk})
      {:cont, acc}
    end

    result = get_following(url, Keyword.put(opts, :into, into))
    streamed = drain_chunks(ref, [])

    case result do
      # Only 200/206 bodies stream; any other status arrives with its body.
      {:ok, %Req.Response{body: ""} = response} -> {:ok, %{response | body: streamed}}
      other -> other
    end
  end

  defp write_into(file) do
    fn {:data, chunk}, acc ->
      case IO.binwrite(file, chunk) do
        :ok -> {:cont, acc}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp promote(tmp, dest_path) do
    case File.rename(tmp, dest_path) do
      :ok ->
        {:ok, dest_path}

      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp drain_chunks(ref, acc) do
    receive do
      {^ref, chunk} -> drain_chunks(ref, [acc | chunk])
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  defp get_following(url, opts) do
    get_following(url, opts, Keyword.get(opts, :max_redirects, @default_max_redirects))
  end

  defp get_following(url, opts, redirects_left) do
    case get(url, opts) do
      {:ok, %Req.Response{status: status} = response} when status in @redirect_statuses ->
        with :ok <- ensure_redirects_left(redirects_left),
             {:ok, next_url} <- redirect_target(url, response) do
          get_following(next_url, opts, redirects_left - 1)
        end

      other ->
        other
    end
  end

  defp ensure_redirects_left(left) when left > 0, do: :ok
  defp ensure_redirects_left(_left), do: {:error, :too_many_redirects}

  defp redirect_target(current_url, response) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        case URI.merge(current_url, location) do
          %URI{scheme: "https"} = uri -> {:ok, URI.to_string(uri)}
          uri -> {:error, {:insecure_redirect, URI.to_string(uri)}}
        end

      [] ->
        {:error, :redirect_without_location}
    end
  end

  defp ensure_profile(profile) do
    _ = Application.ensure_all_started(:inets)

    case :inets.start(:httpc, profile: profile) do
      {:ok, _pid} -> {:ok, profile}
      {:error, {:already_started, _pid}} -> {:ok, profile}
      {:error, reason} -> {:error, {:httpc_profile_unavailable, reason}}
    end
  end

  # Set per call rather than once at boot: the proxy is read from application
  # config, and a test that points a profile at its own fake proxy has to be
  # able to change it without restarting anything.
  #
  # With no proxy configured the options are left alone rather than cleared.
  # `:httpc` has no value meaning "no proxy": its own default is
  # `{undefined, []}`, but `httpc:validate_proxy/1` requires `{{Host, Port},
  # NoProxy}` and rejects anything else, so setting the default back is an
  # error. A fresh profile already has it.
  defp configure_proxy(profile, opts) do
    case Keyword.get_lazy(opts, :proxy, &configured_proxy/0) do
      %{host: host, port: port} -> set_proxy(profile, {{String.to_charlist(host), port}, []})
      _ -> :ok
    end
  end

  defp set_proxy(profile, setting) do
    case :httpc.set_options([{:proxy, setting}, {:https_proxy, setting}], profile) do
      :ok -> :ok
      {:error, reason} -> {:error, {:httpc_options_rejected, reason}}
    end
  end

  defp configured_proxy do
    Application.get_env(:serviceradar_core, :egress_proxy)
  end

  defp request(url, opts, profile) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, timeout)

    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {name, value} ->
        {String.to_charlist(to_string(name)), String.to_charlist(to_string(value))}
      end)

    http_options = [
      ssl: tls_options(opts),
      timeout: :infinity,
      connect_timeout: connect_timeout,
      autoredirect: false
    ]

    request_options = [body_format: :binary, sync: false, stream: {:self, :once}]

    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           http_options,
           request_options,
           profile
         ) do
      {:ok, request_id} -> await(request_id, profile, opts, timeout)
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  # `:httpc` only streams 200/206 bodies; every other status arrives whole, which
  # is what makes a redirect's `location` header readable here without following
  # it. `:stream_start` does not carry the status, but a GET that sends no Range
  # header cannot draw a 206, so a streamed response here is a 200.
  defp await(request_id, profile, opts, timeout) do
    receive do
      {:http, {^request_id, :stream_start, headers, handler}} ->
        stream({request_id, handler}, profile, opts, timeout, headers, 0, nil)

      {:http, {^request_id, {{_version, status, _reason}, headers, body}}} ->
        # Only 200/206 bodies stream, so a non-2xx body is already buffered by
        # the time it lands here. Check it anyway: the cap is the caller's
        # statement about what it is willing to hold.
        if over_limit?(byte_size(body), opts) do
          {:error, :response_too_large}
        else
          {:ok, response(status, headers, body)}
        end

      {:http, {^request_id, {:error, reason}}} ->
        {:error, transport_error(reason)}
    after
      timeout ->
        cancel(request_id, profile)
        {:error, :timeout}
    end
  end

  defp stream({request_id, handler} = stream_id, profile, opts, timeout, headers, size, acc) do
    :ok = :httpc.stream_next(handler)

    receive do
      {:http, {^request_id, :stream, chunk}} ->
        size = size + byte_size(chunk)

        case consume(chunk, size, opts, acc) do
          {:cont, acc} ->
            stream(stream_id, profile, opts, timeout, headers, size, acc)

          {:halt, _acc} ->
            cancel(request_id, profile)
            {:ok, response(200, headers, "")}

          {:error, reason} ->
            cancel(request_id, profile)
            {:error, reason}
        end

      {:http, {^request_id, :stream_end, trailers}} ->
        {:ok, response(200, headers ++ trailers, "")}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, transport_error(reason)}
    after
      timeout ->
        cancel(request_id, profile)
        {:error, :timeout}
    end
  end

  defp consume(chunk, size, opts, acc) do
    if over_limit?(size, opts) do
      {:error, :response_too_large}
    else
      fun = Keyword.fetch!(opts, :into)
      fun.({:data, chunk}, acc || {nil, Req.Response.new(status: 200)})
    end
  end

  defp over_limit?(size, opts) do
    case Keyword.get(opts, :max_bytes) do
      max when is_integer(max) -> size > max
      _ -> false
    end
  end

  defp response(status, headers, body) do
    Req.Response.new(status: status, headers: normalize_headers(headers), body: body)
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  # :httpc reports a connection it could not open as
  # {:failed_connect, [{:to_address, _}, {family, _options, reason}]}. Report it
  # as Req would, so a caller that logs or records the reason says
  # "connection refused" rather than an :httpc term.
  defp transport_error({:failed_connect, info} = error) when is_list(info) do
    case List.last(info) do
      {_family, _options, reason} when is_atom(reason) -> %Req.TransportError{reason: reason}
      _ -> error
    end
  end

  defp transport_error(reason), do: reason

  defp cancel(request_id, profile) do
    _ = :httpc.cancel_request(request_id, profile)
    flush(request_id)
  end

  defp flush(request_id) do
    receive do
      {:http, {^request_id, _}} -> flush(request_id)
      {:http, {^request_id, _, _}} -> flush(request_id)
      {:http, {^request_id, _, _, _}} -> flush(request_id)
    after
      0 -> :ok
    end
  end

  @doc false
  @spec tls_options([option()]) :: keyword()
  def tls_options(opts) do
    [
      verify: :verify_peer,
      depth: @depth,
      versions: @tls_versions,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ] ++ trust_anchors(opts)
  end

  # Release images are intentionally minimal and may carry no OS CA bundle, which
  # is the same reason `ServiceRadar.HTTP.EgressProxy` hands Finch a CAStore
  # `cacertfile`. Keep the two agreeing on where trust comes from.
  defp trust_anchors(opts) do
    cond do
      cacerts = Keyword.get(opts, :cacerts) ->
        [cacerts: cacerts]

      path = Keyword.get(opts, :cacertfile) ->
        [cacertfile: String.to_charlist(path)]

      Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) ->
        [cacertfile: String.to_charlist(CAStore.file_path())]

      true ->
        [cacerts: :public_key.cacerts_get()]
    end
  end
end
