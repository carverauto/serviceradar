defmodule ServiceRadar.Analytics.StarRocks.StreamLoad do
  @moduledoc """
  EventWriter destination for StarRocks Stream Load.

  HTTP 200 is not a successful persistence acknowledgement. The load JSON
  `Status` must be `Success`, loaded rows must match the payload, and filtered
  rows must be zero. Lost responses are reconciled by load label before ACK.

  Transient transport failures get at most three attempts, with exponential
  backoff and jitter. Retries reuse the encoded body and label, starting at the
  FE again so it can select a healthy coordinator. An uncertain commit polls
  the original label instead of issuing another load. The whole call has a
  90-second budget (or the caller's shorter `:http_timeout`), below the default
  JetStream ACK wait; exhaustion returns an error for the normal NAK path.
  """

  alias ServiceRadar.Analytics.StarRocks.LoadHealth

  require Logger

  @success_status "Success"
  @max_attempts 3
  @retry_budget_ms 90_000
  # Follower → leader redirects on the FE state API; a small bound keeps a
  # redirect loop from eating the reconcile budget.
  @max_state_redirects 3

  # Stream Load is a synchronous commit, so the default budget is generous.
  # Callers replaying a backlog pass a shorter `:http_timeout` to bound how
  # long one pass can hold its caller.
  @default_http_timeout_ms 60_000

  def persist(table, rows, opts \\ []) when is_binary(table) and is_list(rows) do
    body = Keyword.get_lazy(opts, :body, fn -> encode_json_rows(rows) end)

    ServiceRadar.Analytics.StarRocks.LoadAdmission.run(byte_size(body), fn ->
      persist_admitted(table, rows, Keyword.put(opts, :body, body))
    end)
  end

  defp persist_admitted(table, rows, opts) do
    http = Keyword.get(opts, :http, &default_http/1)
    config = Keyword.get(opts, :config, %{})
    label = Keyword.get(opts, :label) || load_label(table, rows)

    # A caller that already encoded the rows (Destination sizes loads by their
    # encoded bytes) passes the body so the rows are not encoded twice.
    body = Keyword.get_lazy(opts, :body, fn -> encode_json_rows(rows) end)
    request = stream_load_request(config, table, label, body, opts)
    request = maybe_override_url(request, Keyword.get(opts, :url))
    opts = opts |> Keyword.put(:table, table) |> Keyword.put(:label, label)

    deadline =
      System.monotonic_time(:millisecond) +
        min(Keyword.get(opts, :http_timeout, @retry_budget_ms), @retry_budget_ms)

    retry_load(%{
      request: request,
      http: http,
      count: length(rows),
      rows: rows,
      opts: opts,
      attempt: 1,
      deadline: deadline,
      mode: :load
    })
  end

  defp retry_load(
         %{
           request: request,
           http: http,
           count: count,
           opts: opts,
           attempt: attempt,
           deadline: deadline,
           mode: mode
         } =
           context
       ) do
    {result, dialed} =
      if mode == :reconcile do
        state = state_request(request.config, opts[:label], opts)

        {reconcile_or_retry(opts[:label], opts[:table], count, budget_opts(opts, deadline)),
         state}
      else
        load_once(request, context, Keyword.get(opts, :redirects, 3))
      end

    case result do
      {:error, reason} ->
        delay = retry_delay(attempt)
        retry? = retryable?(reason) and attempt < @max_attempts and remaining(deadline) > delay
        uri = URI.parse(dialed.url)
        fe = URI.parse(Map.get(request.config, :fe_http, "http://127.0.0.1:8030"))

        metadata = %{
          dataset: opts[:dataset] || opts[:table],
          table: opts[:table],
          label: opts[:label],
          attempt: attempt,
          host: uri.host,
          port: uri.port,
          endpoint_role:
            if({uri.host, uri.port} == {fe.host, fe.port}, do: :fe, else: :coordinator),
          reason: reason,
          retrying: retry?,
          cnpg_completed: Keyword.get(opts, :cnpg_completed, false)
        }

        Logger.warning(
          "StarRocks Stream Load attempt failed",
          Keyword.new(Map.put(metadata, :reason, inspect(reason))) ++ [rows: count]
        )

        :telemetry.execute(
          [:serviceradar, :starrocks, :stream_load, :failure],
          %{count: 1, rows: count, retry_delay_ms: if(retry?, do: delay, else: 0)},
          metadata
        )

        LoadHealth.report(metadata.dataset, context.rows, metadata.cnpg_completed,
          timeout: min(500, max(remaining(deadline), 1))
        )

        if retry? and remaining(deadline) > delay do
          Process.sleep(delay)

          {context, mode} =
            case reason do
              # The aborted label persisted nothing; retry the same payload
              # under a disambiguated label instead of re-colliding with it.
              {:label_aborted, _aborted} ->
                {context_with_retry_label(context, attempt + 1), :load}

              {:unresolved_label, _, _} ->
                {context, :reconcile}

              _ ->
                {context, :load}
            end

          retry_load(%{context | attempt: attempt + 1, mode: mode})
        else
          result
        end

      _ ->
        result
    end
  end

  defp load_once(
         request,
         %{http: http, count: count, opts: opts, deadline: deadline} = context,
         redirects
       ) do
    request = %{request | timeout: min(request.timeout, max(remaining(deadline), 1))}

    case http.(request) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] and redirects > 0 ->
        case location_header(resp) do
          nil ->
            {{:error, {:http_status, status, opts[:label]}}, request}

          location ->
            load_once(
              %{request | url: request.url |> URI.merge(location) |> URI.to_string()},
              context,
              redirects - 1
            )
        end

      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {interpret_load(response_body, opts[:label], count, budget_opts(opts, deadline)), request}

      {:ok, %{status: status}} ->
        {{:error, {:http_status, status, opts[:label]}}, request}

      {:error, :timeout} ->
        {reconcile_or_retry(opts[:label], opts[:table], count, budget_opts(opts, deadline)),
         request}

      {:error, reason} ->
        {{:error, {reason, opts[:label]}}, request}
    end
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp budget_opts(opts, deadline),
    do: Keyword.put(opts, :http_timeout, min(http_timeout(opts), max(remaining(deadline), 1)))

  defp retry_delay(attempt) do
    base = 250 * Integer.pow(2, attempt - 1)
    base + :rand.uniform(div(base, 5))
  end

  defp retryable?({:connect_failed, _label}), do: true
  defp retryable?({{:connect_failed, _cause}, _label}), do: true
  defp retryable?({:unresolved_label, _label, _table}), do: true

  # An aborted transaction persisted nothing, so the same content can be
  # loaded again under a disambiguated label (retry_label/2) instead of
  # colliding with the aborted one forever.
  defp retryable?({:label_aborted, _label}), do: true
  defp retryable?({:http_status, status, _label}), do: status in [408, 429, 500, 502, 503, 504]

  defp retryable?({reason, _label})
       when reason in [:closed, :econnreset, :socket_closed_remotely], do: true

  defp retryable?(_reason), do: false

  def load_label(table, rows) when is_binary(table) and is_list(rows) do
    identities =
      rows
      |> Enum.map(&row_identity/1)
      |> Enum.sort()
      |> Enum.join("|")

    :sha256
    |> :crypto.hash(table <> ":" <> identities)
    |> Base.encode16(case: :lower)
    |> then(&("sr-" <> String.slice(&1, 0, 32)))
  end

  defp interpret_load(body, label, expected_count, opts) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} -> interpret_load(payload, label, expected_count, opts)
      {:error, _} -> {:error, {:invalid_load_json, label}}
    end
  end

  defp interpret_load(%{"Status" => @success_status} = payload, label, expected_count, _opts) do
    loaded = int_field(payload, "NumberLoadedRows")
    filtered = int_field(payload, "NumberFilteredRows")

    cond do
      filtered > 0 -> {:quarantine, {:filtered_rows, filtered, label}}
      loaded != expected_count -> {:error, {:row_count_mismatch, loaded, expected_count, label}}
      true -> {:ok, %{label: label, loaded: loaded}}
    end
  end

  defp interpret_load(%{"Status" => "Publish Timeout"}, label, expected_count, opts) do
    reconcile_or_retry(label, Keyword.get(opts, :table, ""), expected_count, opts)
  end

  defp interpret_load(%{"Status" => "Label Already Exists"}, label, expected_count, opts) do
    reconcile_or_retry(label, Keyword.get(opts, :table, ""), expected_count, opts)
  end

  defp interpret_load(%{"Status" => status} = payload, label, _expected_count, _opts) do
    {:error, {:load_status, status, Map.get(payload, "Message"), label}}
  end

  defp interpret_load(_payload, label, _expected_count, _opts) do
    {:error, {:invalid_load_json, label}}
  end

  defp reconcile_or_retry(label, table, expected_count, opts) do
    http = Keyword.get(opts, :http, &default_http/1)
    config = Keyword.get(opts, :config, %{})
    request = state_request(config, label, opts)

    case state_with_redirects(http, request, config, @max_state_redirects) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          # `get_load_state` answers with the label's transaction state, and
          # carries no row counts. COMMITTED is already durable and becomes
          # VISIBLE on its own; the label is a content hash of this batch, so a
          # committed transaction under it holds these rows.
          {:ok, %{"state" => state}} when state in ["COMMITTED", "VISIBLE"] ->
            {:ok, %{label: label, loaded: expected_count, reconciled: true}}

          {:ok, %{"state" => "ABORTED"}} ->
            {:error, {:label_aborted, label}}

          # PREPARE, PREPARED and UNKNOWN are not persistence: retry later.
          _ ->
            {:error, {:unresolved_label, label, table}}
        end

      _ ->
        {:error, {:unresolved_label, label, table}}
    end
  end

  # `get_load_state` answers from the FE leader; a follower (the ClusterIP
  # can route anywhere) replies 307 with the leader's Location. The load path
  # follows the same class of redirect (`load_once/3`), so reconcile must too:
  # an unfollowed 307 used to surface as {:unresolved_label, _, _} even though
  # the label's transaction was VISIBLE on the leader, which JetStream then
  # redelivered forever under the same already-used label (#5387).
  #
  # A redirect is followed only onto the cluster's own FE port: the request
  # carries `config`, and the HTTP layer re-applies Basic auth from it on every
  # hop, so credentials must never be steered somewhere other than an FE. A
  # redirect anywhere else is left unanswered and maps to the unresolved path.
  defp state_with_redirects(http, request, config, redirects) do
    case http.(request) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] and redirects > 0 ->
        case redirect_on_fe_port?(request, resp, config) do
          {:ok, target} ->
            state_with_redirects(http, %{request | url: target}, config, redirects - 1)

          :error ->
            {:ok, resp}
        end

      other ->
        other
    end
  end

  defp redirect_on_fe_port?(request, resp, config) do
    with location when is_binary(location) <- location_header(resp),
         target = URI.merge(URI.parse(request.url), location),
         fe = URI.parse(Map.get(config, :fe_http, "http://127.0.0.1:8030")),
         true <- target.port == fe.port do
      {:ok, URI.to_string(target)}
    else
      _ -> :error
    end
  end

  # Deterministic per attempt: a given aborted label always retries as the
  # same suffixed label, so the retry itself stays idempotent under redelivery.
  defp retry_label(label, attempt), do: "#{label}-a#{attempt}"

  defp context_with_retry_label(context, attempt) do
    new_label = retry_label(context.opts[:label], attempt)

    %{
      context
      | opts: Keyword.put(context.opts, :label, new_label),
        request: replace_label_header(context.request, new_label)
    }
  end

  defp replace_label_header(request, label) do
    headers =
      Enum.map(request.headers, fn
        {"label", _} -> {"label", label}
        other -> other
      end)

    %{request | headers: headers}
  end

  defp maybe_override_url(request, nil), do: request
  defp maybe_override_url(request, url) when is_binary(url), do: %{request | url: url}

  defp location_header(%{headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == "location", do: to_string(value)

      _ ->
        nil
    end)
  end

  defp location_header(_resp), do: nil

  defp stream_load_request(config, table, label, body, opts) do
    database = Map.get(config, :database, "serviceradar")
    fe = Map.get(config, :fe_http, "http://127.0.0.1:8030")

    %{
      method: :put,
      url: "#{fe}/api/#{database}/#{table}/_stream_load",
      headers:
        [
          {"expect", "100-continue"},
          {"content-type", "application/json"},
          {"format", "json"},
          {"strip_outer_array", "true"},
          {"label", label}
        ] ++ partial_update_headers(opts),
      body: body,
      config: config,
      timeout: http_timeout(opts)
    }
  end

  defp http_timeout(opts), do: Keyword.get(opts, :http_timeout, @default_http_timeout_ms)

  defp partial_update_headers(opts) do
    []
    |> maybe_header("partial_update", if(Keyword.get(opts, :partial_update) == true, do: "true"))
    |> maybe_header("columns", columns_header(Keyword.get(opts, :columns)))
    |> maybe_header("merge_condition", Keyword.get(opts, :merge_condition))
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, false), do: headers
  defp maybe_header(headers, name, value), do: headers ++ [{name, value}]

  defp columns_header(columns) when is_list(columns) and columns != [],
    do: Enum.join(columns, ",")

  defp columns_header(_), do: nil

  defp state_request(config, label, opts) do
    database = Map.get(config, :database, "serviceradar")
    fe = Map.get(config, :fe_http, "http://127.0.0.1:8030")

    %{
      method: :get,
      url: "#{fe}/api/#{database}/get_load_state?label=#{label}",
      headers: [],
      body: nil,
      config: config,
      timeout: http_timeout(opts)
    }
  end

  defp encode_json_rows(rows), do: Jason.encode!(rows)

  defp row_identity(row) when is_map(row) do
    id = ServiceRadar.Analytics.StarRocks.Identity.record_id(:flows, row)

    case Map.get(row, "attribution_version") || Map.get(row, :attribution_version) do
      version when is_integer(version) and version > 0 -> "#{id}:attribution:#{version}"
      _ -> id
    end
  end

  defp int_field(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  end

  defp default_http(request) do
    timeout = Map.get(request, :timeout) || @default_http_timeout_ms

    # OTP 28.1 httpc automatically replays 503 Retry-After responses and has no
    # switch to disable that. Req's explicit retry/redirect controls keep this
    # module in charge of both the attempt budget and the actual dialed host.
    result =
      with {:ok, _} <- Application.ensure_all_started(:req) do
        Req.request(
          method: request.method,
          url: request.url,
          headers: request.headers ++ request_auth(request),
          body: request.body,
          decode_body: false,
          retry: false,
          redirect: false,
          request_timeout: timeout,
          receive_timeout: timeout,
          pool_timeout: min(5_000, timeout),
          connect_options: [timeout: min(5_000, timeout)]
        )
      end

    case result do
      {:ok, response} ->
        headers =
          Enum.flat_map(response.headers, fn {key, values} ->
            Enum.map(List.wrap(values), &{key, &1})
          end)

        {:ok, %{status: response.status, headers: headers, body: response.body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:connect_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_auth(%{config: %{user: user, password: password}}) do
    [{"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}]
  end

  defp request_auth(_request), do: []
end
