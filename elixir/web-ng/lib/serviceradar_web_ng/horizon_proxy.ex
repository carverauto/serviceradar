defmodule ServiceRadarWebNG.HorizonProxy do
  @moduledoc """
  Server-side control-plane proxy for Horizon API endpoints.

  Enforces a strict path/method allowlist, delegates upstream credential
  resolution and SSRF validation to `ServiceRadarWebNG.HorizonProxy.Upstream`,
  and forwards requests with the upstream Bearer token injected server-side.
  """

  alias ServiceRadarWebNG.HorizonProxy.Upstream

  require Logger

  @receive_timeout_ms 15_000
  @connect_timeout_ms 5_000
  @get_max_retries 2
  @get_retry_delay_ms 50

  @read_permission "observability.events.view"
  @traces_read_permission "observability.traces.view"
  @rules_read_permission "observability.rules.view"
  @rules_create_permission "observability.rules.create"
  @rules_update_permission "observability.rules.update"
  @rules_delete_permission "observability.rules.delete"
  @write_permission "settings.integrations.manage"

  @default_accept_header "application/json"
  @max_accept_header_bytes 512
  @default_response_content_type "application/json; charset=utf-8"
  @control_chars_regex ~r/[\x00-\x1F\x7F]/
  @accept_header_regex ~r/\A[A-Za-z0-9!#$%&'*+.^_`|~\/,;=\- "]+\z/
  @allowed_non_json_media_types MapSet.new([
                                  "application/vnd.apache.arrow.stream",
                                  "application/vnd.apache.arrow.file",
                                  "application/octet-stream",
                                  "application/gzip",
                                  "text/csv"
                                ])
  @allowed_json_media_types MapSet.new([
                              "application/json",
                              "application/problem+json",
                              "application/x-ndjson",
                              "application/ndjson",
                              "application/vnd.api+json",
                              "application/ld+json"
                            ])

  @id_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type route_match :: %{
          upstream_path: String.t(),
          required_permission: String.t(),
          method: :get | :post | :patch | :delete
        }

  @type upstream_config :: Upstream.config()

  defdelegate resolve_upstream(), to: Upstream, as: :resolve
  defdelegate validate_base_url(url), to: Upstream

  @doc """
  Validates and resolves a proxied Horizon request against the strict route
  allowlist. Rejects path traversal, percent-encoded slashes/dots, and any
  unlisted route or HTTP method with `{:error, :not_found}`.
  """
  @spec resolve_route(String.t(), String.t(), [String.t()], String.t()) ::
          {:ok, route_match()} | {:error, :not_found}
  def resolve_route(method, version, path_segments, raw_request_path)
      when is_binary(method) and is_binary(version) and is_list(path_segments) and is_binary(raw_request_path) do
    with :ok <- validate_raw_request_path(raw_request_path),
         {:ok, method_atom} <- normalize_method(method),
         {:ok, normalized_segments} <- normalize_segments(path_segments),
         {:ok, upstream_path, permission} <-
           match_allowlisted_route(method_atom, String.downcase(version), normalized_segments) do
      {:ok,
       %{
         upstream_path: upstream_path,
         required_permission: permission,
         method: method_atom
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_route(_method, _version, _path_segments, _raw_request_path), do: {:error, :not_found}

  @doc """
  Validates a query string for forwarding to Horizon. Rejects control
  characters, malformed RFC 3986 percent-encoding or query syntax, and `token`
  query parameters (tokens must never travel in URLs).
  """
  @spec validate_query_string(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_query}
  def validate_query_string(nil), do: {:ok, ""}
  def validate_query_string(""), do: {:ok, ""}

  def validate_query_string(query_string) when is_binary(query_string) do
    cond do
      not valid_query_syntax?(query_string) ->
        {:error, :invalid_query}

      has_token_query_param?(query_string) ->
        {:error, :invalid_query}

      true ->
        {:ok, query_string}
    end
  end

  def validate_query_string(_), do: {:error, :invalid_query}

  @doc """
  Forwards an allowlisted request to the resolved Horizon upstream with the
  server-side Bearer API key injected.
  """
  @spec forward(route_match(), upstream_config(), keyword()) ::
          {:ok, %{status: pos_integer(), content_type: String.t(), body: binary()}}
          | {:error, :upstream_timeout | :upstream_unavailable}
  def forward(route, upstream, opts \\ []) do
    query_string = Keyword.get(opts, :query_string, "")
    body = Keyword.get(opts, :body)
    accept = opts |> Keyword.get(:accept) |> sanitize_accept_header()
    url = build_upstream_url(upstream.base_url, route.upstream_path, query_string)

    headers =
      maybe_put_content_type(
        [{"authorization", "Bearer #{upstream.api_key}"}, {"accept", accept}],
        route.method,
        body
      )

    finch_opt =
      if Process.whereis(ServiceRadarWebNG.HorizonFinch) do
        [finch: [name: ServiceRadarWebNG.HorizonFinch]]
      else
        [
          finch: [
            conn_opts: [transport_opts: [timeout: @connect_timeout_ms]],
            conn_max_idle_time: 10_000,
            http2: [
              ping_interval: 15_000,
              max_connection_age: 300_000,
              max_connection_age_jitter: 30_000
            ]
          ]
        ]
      end

    base_opts =
      [
        method: route.method,
        url: url,
        headers: headers,
        receive_timeout: @receive_timeout_ms,
        redirect: false,
        decode_body: false
      ] ++ finch_opt ++ retry_opts(route.method)

    req_opts = maybe_put_body(base_opts, route.method, body)

    http_client =
      Application.get_env(:serviceradar_web_ng, :horizon_proxy_http_client, &Req.request/1)

    case http_client.(req_opts) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok,
         %{
           status: status,
           content_type: extract_response_content_type(resp_headers),
           body: normalize_response_body(resp_body)
         }}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Horizon proxy upstream request timed out for #{route.upstream_path}")
        {:error, :upstream_timeout}

      {:error, reason} ->
        Logger.warning("Horizon proxy upstream request failed for #{route.upstream_path}: #{sanitize_error(reason)}")
        {:error, :upstream_unavailable}
    end
  end

  # --- Allowlist Matching ---

  defp match_allowlisted_route(:get, "v1", ["outages"]), do: {:ok, "/api/v1/outages", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["outages", "search"]), do: {:ok, "/api/v1/outages/search", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["providers", "health"]),
    do: {:ok, "/api/v1/providers/health", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["weathermap"]), do: {:ok, "/api/v1/weathermap", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["weathermap", "timeline"]),
    do: {:ok, "/api/v1/weathermap/timeline", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["pops", "map"]), do: {:ok, "/api/v1/pops/map", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["topology", "snapshot"]),
    do: {:ok, "/api/v1/topology/snapshot", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "status"]), do: {:ok, "/api/v1/feeds/status", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "paths"]), do: {:ok, "/api/v1/feeds/paths", @traces_read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "sav"]), do: {:ok, "/api/v1/feeds/sav", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "reference", "manifest"]),
    do: {:ok, "/api/v1/feeds/reference/manifest", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "reference", "asns.ndjson.gz"]),
    do: {:ok, "/api/v1/feeds/reference/asns.ndjson.gz", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["feeds", "reference", "prefixes.ndjson.gz"]),
    do: {:ok, "/api/v1/feeds/reference/prefixes.ndjson.gz", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["sav", "findings"]), do: {:ok, "/api/v1/sav/findings", @read_permission}

  defp match_allowlisted_route(:post, "v1", ["sav", "findings"]), do: {:ok, "/api/v1/sav/findings", @write_permission}

  defp match_allowlisted_route(:get, "v1", ["sav", "regressions"]), do: {:ok, "/api/v1/sav/regressions", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["vendor-status"]), do: {:ok, "/api/v1/vendor-status", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["statuspages"]), do: {:ok, "/api/v1/statuspages", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["intel", "lookup"]), do: {:ok, "/api/v1/intel/lookup", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["paths", "dag"]), do: {:ok, "/api/v1/paths/dag", @traces_read_permission}

  defp match_allowlisted_route(:get, "v1", ["bgp", "anomalies"]), do: {:ok, "/api/v1/bgp/anomalies", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["bgp", "sankey"]), do: {:ok, "/api/v1/bgp/sankey", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["bgp", "zombies"]), do: {:ok, "/api/v1/bgp/zombies", @read_permission}

  defp match_allowlisted_route(:get, "v2", ["bgp", "zombies"]), do: {:ok, "/api/v2/bgp/zombies", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["public", "bgp", "zombies"]),
    do: {:ok, "/api/v1/public/bgp/zombies", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["public", "reports", token]) do
    if valid_id?(token),
      do: {:ok, "/api/v1/public/reports/#{token}", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, ver, ["bgp", "watchlist"]) when ver in ["v1", "v2"],
    do: {:ok, "/api/v2/bgp/watchlist", @read_permission}

  defp match_allowlisted_route(:post, ver, ["bgp", "watchlist"]) when ver in ["v1", "v2"],
    do: {:ok, "/api/v2/bgp/watchlist", @write_permission}

  defp match_allowlisted_route(:get, ver, ["bgp", "watchlist", "events"]) when ver in ["v1", "v2"],
    do: {:ok, "/api/v2/bgp/watchlist/events", @read_permission}

  defp match_allowlisted_route(:delete, ver, ["bgp", "watchlist", id]) when ver in ["v1", "v2"] and id != "events" do
    if valid_id?(id),
      do: {:ok, "/api/v2/bgp/watchlist/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["snapshots"]), do: {:ok, "/api/v1/snapshots", @read_permission}

  defp match_allowlisted_route(:post, "v1", ["snapshots"]), do: {:ok, "/api/v1/snapshots", @write_permission}

  defp match_allowlisted_route(:get, "v1", ["snapshots", "shared", token]) do
    if valid_id?(token),
      do: {:ok, "/api/v1/snapshots/shared/#{token}", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["snapshots", id]) when id != "shared" do
    if valid_id?(id),
      do: {:ok, "/api/v1/snapshots/#{id}", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v1", ["snapshots", id]) when id != "shared" do
    if valid_id?(id),
      do: {:ok, "/api/v1/snapshots/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v1", ["snapshots", id, "share"]) when id != "shared" do
    if valid_id?(id),
      do: {:ok, "/api/v1/snapshots/#{id}/share", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v2", ["reports", "isp-accountability"]),
    do: {:ok, "/api/v2/reports/isp-accountability", @read_permission}

  defp match_allowlisted_route(:post, "v2", ["reports", "isp-accountability"]),
    do: {:ok, "/api/v2/reports/isp-accountability", @write_permission}

  defp match_allowlisted_route(:get, "v2", ["reports", "isp-accountability", "live"]),
    do: {:ok, "/api/v2/reports/isp-accountability/live", @read_permission}

  defp match_allowlisted_route(:get, "v2", ["reports", "isp-accountability", id]) when id != "live" do
    if valid_id?(id),
      do: {:ok, "/api/v2/reports/isp-accountability/#{id}", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v2", ["reports", "isp-accountability", id]) when id != "live" do
    if valid_id?(id),
      do: {:ok, "/api/v2/reports/isp-accountability/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:post, "v2", ["agents", "enrollment-tokens"]),
    do: {:ok, "/api/v2/agents/enrollment-tokens", @write_permission}

  defp match_allowlisted_route(:get, "v2", ["targets"]), do: {:ok, "/api/v2/targets", @read_permission}

  defp match_allowlisted_route(:post, "v2", ["targets"]), do: {:ok, "/api/v2/targets", @write_permission}

  defp match_allowlisted_route(:post, "v2", ["targets", "verify-ownership"]),
    do: {:ok, "/api/v2/targets/verify-ownership", @write_permission}

  defp match_allowlisted_route(:delete, "v2", ["targets", id]) when id != "verify-ownership" do
    if valid_id?(id),
      do: {:ok, "/api/v2/targets/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v2", ["targets", id, "telemetry"]) when id != "verify-ownership" do
    if valid_id?(id),
      do: {:ok, "/api/v2/targets/#{id}/telemetry", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v2", ["branch-allowlists"]),
    do: {:ok, "/api/v2/branch-allowlists", @read_permission}

  defp match_allowlisted_route(:post, "v2", ["branch-allowlists"]),
    do: {:ok, "/api/v2/branch-allowlists", @write_permission}

  defp match_allowlisted_route(:delete, "v2", ["branch-allowlists"]),
    do: {:ok, "/api/v2/branch-allowlists", @write_permission}

  defp match_allowlisted_route(:post, "v2", ["pops", "provision"]), do: {:ok, "/api/v2/pops/provision", @write_permission}

  defp match_allowlisted_route(:get, "v1", ["alerts", "rules"]), do: {:ok, "/api/v1/alerts/rules", @rules_read_permission}

  defp match_allowlisted_route(:post, "v1", ["alerts", "rules"]),
    do: {:ok, "/api/v1/alerts/rules", @rules_create_permission}

  defp match_allowlisted_route(:get, "v1", ["alerts", "rules", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/alerts/rules/#{id}", @rules_read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:patch, "v1", ["alerts", "rules", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/alerts/rules/#{id}", @rules_update_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v1", ["alerts", "rules", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/alerts/rules/#{id}", @rules_delete_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["alerts", "events"]), do: {:ok, "/api/v1/alerts/events", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["slos"]), do: {:ok, "/api/v1/slos", @read_permission}

  defp match_allowlisted_route(:post, "v1", ["slos"]), do: {:ok, "/api/v1/slos", @write_permission}

  defp match_allowlisted_route(:get, "v1", ["slos", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/slos/#{id}", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v1", ["slos", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/slos/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["slos", id, "rollups"]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/slos/#{id}/rollups", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["slos", id, "burn-rate"]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/slos/#{id}/burn-rate", @read_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["webhooks"]), do: {:ok, "/api/v1/webhooks", @write_permission}

  defp match_allowlisted_route(:post, "v1", ["webhooks"]), do: {:ok, "/api/v1/webhooks", @write_permission}

  defp match_allowlisted_route(:post, "v1", ["webhooks", "subscriptions"]),
    do: {:ok, "/api/v1/webhooks/subscriptions", @write_permission}

  defp match_allowlisted_route(:delete, "v1", ["webhooks", "subscriptions", id]) do
    if valid_id?(id),
      do: {:ok, "/api/v1/webhooks/subscriptions/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:delete, "v1", ["webhooks", id]) when id != "subscriptions" do
    if valid_id?(id),
      do: {:ok, "/api/v1/webhooks/#{id}", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:post, "v1", ["webhooks", id, "rebind"]) when id != "subscriptions" do
    if valid_id?(id),
      do: {:ok, "/api/v1/webhooks/#{id}/rebind", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["webhooks", id, "deliveries"]) when id != "subscriptions" do
    if valid_id?(id),
      do: {:ok, "/api/v1/webhooks/#{id}/deliveries", @write_permission},
      else: {:error, :not_found}
  end

  defp match_allowlisted_route(:get, "v1", ["fusion", "outages"]), do: {:ok, "/api/v1/fusion/outages", @read_permission}

  defp match_allowlisted_route(:get, "v1", ["fusion", "bgp", "anomalies"]),
    do: {:ok, "/api/v1/fusion/bgp/anomalies", @read_permission}

  defp match_allowlisted_route(:post, "v1", ["fusion", "impact-reports"]),
    do: {:ok, "/api/v1/fusion/impact-reports", @write_permission}

  defp match_allowlisted_route(_method, _version, _segments), do: {:error, :not_found}

  defp validate_raw_request_path(raw_path) do
    lower = String.downcase(raw_path)

    if String.contains?(lower, ["..", "%2f", "%5c", "%2e", "\\", "\0", "\r", "\n"]) do
      {:error, :invalid_path}
    else
      :ok
    end
  end

  defp normalize_method(method) do
    case String.upcase(method) do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PATCH" -> {:ok, :patch}
      "DELETE" -> {:ok, :delete}
      _ -> {:error, :unsupported_method}
    end
  end

  defp normalize_segments(segments) do
    if Enum.all?(segments, &safe_segment?/1) do
      {:ok, segments}
    else
      {:error, :invalid_segment}
    end
  end

  defp safe_segment?(seg) when is_binary(seg) do
    seg != "" and seg not in [".", ".."] and
      not String.contains?(seg, ["/", "\\", "..", "%", "\0", "\r", "\n"])
  end

  defp safe_segment?(_), do: false

  defp valid_id?(id) when is_binary(id) do
    id not in [".", ".."] and not String.contains?(id, "..") and Regex.match?(@id_regex, id)
  end

  defp valid_id?(_), do: false

  defp valid_query_syntax?(query_string) do
    not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, query_string) and
      match?({:ok, %URI{query: ^query_string, fragment: nil}}, URI.new("?" <> query_string))
  end

  defp has_token_query_param?(query_string) do
    query_string
    |> URI.query_decoder(:rfc3986)
    |> Enum.any?(fn {key, _val} -> String.downcase(key) == "token" end)
  rescue
    ArgumentError -> true
  end

  # --- HTTP Helpers ---

  defp build_upstream_url(base_url, upstream_path, ""), do: base_url <> upstream_path
  defp build_upstream_url(base_url, upstream_path, qs), do: base_url <> upstream_path <> "?" <> qs

  defp maybe_put_content_type(headers, method, body) when method in [:post, :patch] and is_binary(body) do
    [{"content-type", "application/json"} | headers]
  end

  defp maybe_put_content_type(headers, _method, _body), do: headers

  defp maybe_put_body(opts, method, body) when method in [:post, :patch] and is_binary(body) do
    Keyword.put(opts, :body, body)
  end

  defp maybe_put_body(opts, _method, _body), do: opts

  defp retry_opts(:get) do
    [
      retry: &retry_stale_get?/2,
      max_retries: @get_max_retries,
      retry_delay: &get_retry_delay/1,
      retry_log_level: :debug
    ]
  end

  defp retry_opts(_method), do: [retry: false]

  defp retry_stale_get?(%Req.Request{method: :get}, %Req.TransportError{reason: reason})
       when reason in [:closed, :econnreset, :epipe, :etimedout], do: true

  defp retry_stale_get?(%Req.Request{method: :get}, %Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available, :connection_not_ready, :closed, :closed_for_writing], do: true

  defp retry_stale_get?(%Req.Request{method: :get}, %Req.HTTPError{protocol: :http2, reason: {kind, _}})
       when kind in [:server_closed_connection, :server_closed_request], do: true

  defp retry_stale_get?(%Req.Request{method: :get}, %Req.HTTPError{
         protocol: :http2,
         reason: {:server_closed_connection, _, _}
       }), do: true

  defp retry_stale_get?(_request, _response_or_error), do: false

  defp get_retry_delay(_retry_count), do: @get_retry_delay_ms

  defp sanitize_accept_header(accept) when is_binary(accept) do
    if Regex.match?(@control_chars_regex, accept) do
      @default_accept_header
    else
      trimmed = String.trim(accept)

      if trimmed != "" and byte_size(trimmed) <= @max_accept_header_bytes and
           String.contains?(trimmed, "/") and Regex.match?(@accept_header_regex, trimmed) do
        trimmed
      else
        @default_accept_header
      end
    end
  end

  defp sanitize_accept_header(_), do: @default_accept_header

  defp extract_response_content_type(headers) when is_map(headers) do
    ct =
      Enum.find_value(headers, fn
        {k, [v | _]} when is_binary(v) ->
          if String.downcase(to_string(k)) == "content-type", do: v

        {k, v} when is_binary(v) ->
          if String.downcase(to_string(k)) == "content-type", do: v

        _ ->
          nil
      end)

    if allowed_response_content_type?(ct) do
      String.trim(ct)
    else
      @default_response_content_type
    end
  end

  defp extract_response_content_type(_), do: @default_response_content_type

  defp allowed_response_content_type?(ct) when is_binary(ct) do
    if Regex.match?(@control_chars_regex, ct) do
      false
    else
      media_type =
        ct
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()

      MapSet.member?(@allowed_non_json_media_types, media_type) or json_media_type?(media_type)
    end
  end

  defp allowed_response_content_type?(_), do: false

  defp json_media_type?(media_type) do
    MapSet.member?(@allowed_json_media_types, media_type)
  end

  defp normalize_response_body(body) when is_binary(body), do: body
  defp normalize_response_body(_), do: ""

  defp sanitize_error(%{__struct__: struct, reason: reason}), do: "#{inspect(struct)}(#{inspect(reason)})"
  defp sanitize_error(%{__struct__: struct}), do: inspect(struct)
  defp sanitize_error(reason) when is_atom(reason), do: inspect(reason)
  defp sanitize_error(_), do: "upstream_error"
end
