defmodule ServiceRadar.Analytics.StarRocks.StreamLoad do
  @moduledoc """
  EventWriter destination for StarRocks Stream Load.

  HTTP 200 is not a successful persistence acknowledgement. The load JSON
  `Status` must be `Success`, loaded rows must match the payload, and filtered
  rows must be zero. Lost responses are reconciled by load label before ACK.

  Transient transport failures get at most three attempts, with exponential
  backoff and jitter. Retries reuse the encoded body and label, starting at the
  FE again so it can select a healthy coordinator. An uncertain commit polls
  the original label instead of issuing another load, and so does a load
  refused because its label is already used: while that label's transaction
  is still running (PREPARE or PREPARED), whether it is this caller's lost
  attempt or another loader of the same batch, the call waits for it to commit
  or abort rather than failing a load that is about to succeed. A label the FE
  has no transaction for (`UNKNOWN`, typically a load that timed out before its
  coordinator began one) persisted nothing, so the retry loads it again under
  the same label; if the first attempt starts after all, the label refuses the
  second and the reconcile above takes over.

  The whole call, that wait included, has a 90-second budget (or the caller's
  shorter `:http_timeout`), below the default JetStream ACK wait; exhaustion
  returns an error for the normal NAK path.
  """

  alias ServiceRadar.Analytics.StarRocks.LoadHealth

  require Logger

  @success_status "Success"
  @max_attempts 3
  @retry_budget_ms 90_000
  # Follower → leader redirects on the FE state API; a small bound keeps a
  # redirect loop from eating the reconcile budget.
  @max_state_redirects 3

  # A label whose transaction is still running is polled, not reloaded: first
  # after 200 ms, then doubling to at most 2 s, until it commits, aborts or the
  # load budget runs out.
  @in_flight_states ["PREPARE", "PREPARED"]
  @in_flight_poll_ms 200
  @in_flight_poll_max_ms 2_000

  # Stream Load is a synchronous commit, so the default budget is generous.
  # Callers replaying a backlog pass a shorter `:http_timeout` to bound how
  # long one pass can hold its caller.
  @default_http_timeout_ms 60_000

  # How long a load waits for `100 Continue` (or an early final response)
  # before sending its body anyway, as RFC 9110 15.2.1 allows a client to.
  @continue_wait_ms 3_000

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
      deadline: deadline
    })
  end

  defp retry_load(
         %{request: request, count: count, opts: opts, attempt: attempt, deadline: deadline} =
           context
       ) do
    {result, dialed} = load_once(request, context, Keyword.get(opts, :redirects, 3))

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
          "StarRocks Stream Load attempt failed: dataset=#{metadata.dataset} table=#{metadata.table} label=#{metadata.label} attempt=#{attempt}/#{@max_attempts} host=#{uri.host}:#{uri.port} reason=#{inspect(reason)}",
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

          # The aborted label persisted nothing; retry the same payload under a
          # disambiguated label instead of re-colliding with it. Every other
          # retry, an unresolved label included, loads again under the same
          # label: StarRocks refuses a label whose transaction exists, and that
          # refusal reconciles instead of loading twice.
          context =
            case reason do
              {:label_aborted, _aborted} -> context_with_retry_label(context, attempt + 1)
              _ -> context
            end

          retry_load(%{context | attempt: attempt + 1})
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

      {:ok, %{status: status, body: response_body}} ->
        if is_binary(response_body) and response_body != "" do
          Logger.warning(
            "StarRocks Stream Load HTTP error response: status=#{status} table=#{opts[:table]} label=#{opts[:label]} body=#{response_body}"
          )
        end

        {{:error, {:http_status, status, opts[:label]}}, request}

      {:ok, %{status: status}} ->
        {{:error, {:http_status, status, opts[:label]}}, request}

      {:error, :timeout} ->
        {reconcile_or_retry(
           opts[:label],
           opts[:table],
           count,
           budget_opts(opts, deadline),
           :http_timeout
         ), request}

      {:error, reason} ->
        if stopping_reason?(reason) do
          exit(reason)
        else
          {{:error, {reason, opts[:label]}}, request}
        end
    end
  end

  # A stopping node surfaces as these reasons. Re-raising them as exits lets
  # LoadAdmission.run/2 map them to :load_admission_unavailable, so the batch
  # counts as not attempted instead of as a failed load.
  defp stopping_reason?(reason) when reason in [:terminating, :shutdown, :noproc], do: true
  defp stopping_reason?({reason, _}) when reason in [:terminating, :shutdown, :noproc], do: true
  defp stopping_reason?(_reason), do: false

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

  defp retryable?({:load_status, status, msg, _label})
       when status in ["Fail", "FAIL"] and is_binary(msg),
       do: retryable_load_message?(msg)

  defp retryable?({reason, _label})
       when reason in [:closed, :econnreset, :socket_closed_remotely], do: true

  defp retryable?(_reason), do: false

  defp retryable_load_message?(msg) do
    String.contains?(msg, "Couldn't open transport for :0") or
      String.contains?(msg, "Could not resolve host for client socket") or
      String.contains?(msg, "[E104]Fail to read from Socket")
  end

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

  defp interpret_load(%{"Status" => status}, label, expected_count, opts)
       when status in ["Publish Timeout", "Label Already Exists", "LABEL_ALREADY_EXISTS"] do
    reconcile_or_retry(
      label,
      Keyword.get(opts, :table, ""),
      expected_count,
      opts,
      {:status, status}
    )
  end

  defp interpret_load(%{"Message" => msg} = payload, label, expected_count, opts)
       when is_binary(msg) do
    if msg =~ "has already been used" or msg =~ "Label Already Exists" or
         msg =~ "LABEL_ALREADY_EXISTS" do
      reconcile_or_retry(
        label,
        Keyword.get(opts, :table, ""),
        expected_count,
        opts,
        {:status, Map.get(payload, "Status")}
      )
    else
      {:error, {:load_status, Map.get(payload, "Status"), msg, label}}
    end
  end

  defp interpret_load(%{"Status" => status} = payload, label, _expected_count, _opts) do
    {:error, {:load_status, status, Map.get(payload, "Message"), label}}
  end

  defp interpret_load(_payload, label, _expected_count, _opts) do
    {:error, {:invalid_load_json, label}}
  end

  # The caller's `opts[:http_timeout]` is already capped at what is left of the
  # load budget, so the whole reconcile, including any wait below, ends inside
  # that budget and therefore inside the JetStream ACK wait.
  #
  # `trigger` records why reconciliation started (the load's own status or an
  # HTTP timeout) so an unresolved outcome can be logged with both that cause
  # and the state API's actual answer.
  defp reconcile_or_retry(label, table, expected_count, opts, trigger) do
    deadline = System.monotonic_time(:millisecond) + http_timeout(opts)

    opts
    |> Keyword.put(:reconcile_trigger, trigger)
    |> then(&await_label(label, table, expected_count, &1, deadline, @in_flight_poll_ms))
  end

  defp await_label(label, table, expected_count, opts, deadline, delay) do
    case label_state(label, Keyword.put(opts, :http_timeout, max(remaining(deadline), 1))) do
      # `get_load_state` answers with the label's transaction state, and
      # carries no row counts. COMMITTED is already durable and becomes
      # VISIBLE on its own; the label is a content hash of this batch, so a
      # committed transaction under it holds these rows.
      {:ok, state} when state in ["COMMITTED", "VISIBLE"] ->
        {:ok, %{label: label, loaded: expected_count, reconciled: true}}

      {:ok, "ABORTED"} ->
        {:error, {:label_aborted, label}}

      # The label's transaction is still running: under this caller after a
      # lost response, or under another loader of the same batch that won the
      # label. A second load would only collide with it again, and its outcome
      # is this batch's outcome, so wait for it instead of failing while it is
      # still in flight. The wait ends with the load budget.
      {:ok, state} when state in @in_flight_states ->
        if remaining(deadline) > delay do
          Process.sleep(delay)

          await_label(
            label,
            table,
            expected_count,
            opts,
            deadline,
            min(delay * 2, @in_flight_poll_max_ms)
          )
        else
          {:error, {:unresolved_label, label, table}}
        end

      # UNKNOWN, or no answer: not persistence; the caller's retry path decides.
      answer ->
        Logger.warning(
          "StarRocks Stream Load label unresolved: table=#{table} label=#{label} trigger=#{inspect(opts[:reconcile_trigger])} state_answer=#{inspect(answer, limit: 20, printable_limit: 200)}"
        )

        {:error, {:unresolved_label, label, table}}
    end
  end

  defp label_state(label, opts) do
    http = Keyword.get(opts, :http, &default_http/1)
    config = Keyword.get(opts, :config, %{})

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           state_with_redirects(
             http,
             state_request(config, label, opts),
             config,
             @max_state_redirects
           ),
         {:ok, %{"state" => state}} when is_binary(state) <- Jason.decode(body) do
      {:ok, state}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:ok, decoded} -> {:error, {:no_state, decoded}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
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

    # The FE redirect and the BE can both answer a load from its headers alone
    # (e.g. "Label already used") without reading the body. A pooled socket
    # left with that unread body hands the next load a stale 400, so every
    # load gets its own connection.
    %{
      method: :put,
      url: "#{fe}/api/#{database}/#{table}/_stream_load",
      headers:
        [
          {"connection", "close"},
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
    identity = "#{id}:#{content_fingerprint(row)}"

    case Map.get(row, "attribution_version") || Map.get(row, :attribution_version) do
      version when is_integer(version) and version > 0 -> "#{identity}:attribution:#{version}"
      _ -> identity
    end
  end

  # The label must name the row's content, not only its id. A producer that
  # replaces a row by id -- a Trivy report's event across rescans, a lifecycle
  # transition on an aligned (id, time) -- delivers the same id with new
  # content; under an id-only label StarRocks refuses the load as already
  # used and reconciliation reports the old load's success, so the new row
  # never lands (and a replace delete has already removed the old one). A
  # true redelivery encodes identical rows, so it keeps the same label and
  # still reconciles. `created_at` is excluded: encoders stamp it at encode
  # time when a row carries none, so it differs across redeliveries of the
  # same observation.
  defp content_fingerprint(row) do
    canonical =
      row
      |> Enum.reject(fn {key, _value} -> to_string(key) == "created_at" end)
      |> Map.new()
      |> canonical_term()

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # A struct is a value, not a document. An encoded row can still carry one
  # inside a JSON column (a BMP routing event's metadata holds its DateTime
  # `event_time`), and structs do not implement Enumerable.
  defp canonical_term(%_{} = struct), do: struct

  defp canonical_term(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp int_field(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  end

  # A load body is sent only after the server asks for it. The FE answers a
  # Stream Load with a 307 from its headers alone and closes the connection,
  # and a coordinator can reject a load from its headers ("Label already
  # used"). Writing the body regardless races that close: a large body is
  # still being written when the peer resets the socket, so the load fails
  # with `:closed` and its real answer is lost. Req (Finch) cannot wait for
  # `100 Continue`, so loads drive Mint directly; body-less requests (label
  # state polls) stay on Req.
  defp default_http(%{body: body} = request) when is_binary(body) and body != "" do
    timeout = Map.get(request, :timeout) || @default_http_timeout_ms
    uri = URI.parse(request.url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    target = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path || "/"
    deadline = System.monotonic_time(:millisecond) + timeout

    headers =
      Enum.map(request.headers ++ request_auth(request), fn {name, value} ->
        {to_string(name), value}
      end) ++
        [{"content-length", Integer.to_string(byte_size(body))}]

    connected =
      Mint.HTTP.connect(scheme, uri.host, uri.port,
        mode: :passive,
        protocols: [:http1],
        transport_opts: [timeout: min(5_000, timeout)]
      )

    case connected do
      {:ok, conn} ->
        conn
        |> Mint.HTTP.request(method_name(request.method), target, headers, :stream)
        |> continue_load(body, deadline)
        |> close_load_conn(conn)
        |> load_result()

      {:error, error} ->
        load_result({:error, error})
    end
  end

  defp default_http(request) do
    timeout = Map.get(request, :timeout) || @default_http_timeout_ms

    # OTP 28.1 httpc automatically replays 503 Retry-After responses and has no
    # switch to disable that. Req's explicit retry/redirect controls keep this
    # module in charge of both the attempt budget and the actual dialed host.
    result =
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
        finch: [
          pool_timeout: min(5_000, timeout),
          conn_opts: [transport_opts: [timeout: min(5_000, timeout)]]
        ]
      )

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
        if stopping_reason?(reason) do
          exit(reason)
        else
          {:error, reason}
        end
    end
  end

  defp continue_load({:error, _conn, _error} = error, _body, _deadline), do: error

  defp continue_load({:ok, conn, ref}, body, deadline) do
    wait_until = min(deadline, System.monotonic_time(:millisecond) + @continue_wait_ms)

    case await_response(conn, ref, %{status: nil, headers: [], body: []}, wait_until, :continue) do
      # The server answered before asking for the body: return that answer
      # without ever writing the body.
      {:ok, conn, %{status: status} = response} when status >= 200 ->
        {:ok, conn, response}

      {:continue, conn} ->
        with {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, body),
             {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof) do
          await_response(conn, ref, %{status: nil, headers: [], body: []}, deadline, :final)
        end

      other ->
        other
    end
  end

  # `:continue` returns as soon as a 1xx arrives or the wait elapses; `:final`
  # reads through to the end of the final response.
  defp await_response(conn, ref, acc, until, phase) do
    case Mint.HTTP.recv(conn, 0, max(until - System.monotonic_time(:millisecond), 1)) do
      {:ok, conn, responses} ->
        case Enum.reduce(responses, {:more, acc}, &collect_response(&1, &2, ref)) do
          {:continue, _acc} when phase == :continue ->
            {:continue, conn}

          {:continue, _acc} ->
            await_response(conn, ref, %{acc | status: nil, headers: []}, until, phase)

          {:done, acc} ->
            {:ok, conn, acc}

          {:more, acc} ->
            await_response(conn, ref, acc, until, phase)
        end

      {:error, conn, %Mint.TransportError{reason: :timeout}, _responses}
      when phase == :continue ->
        {:continue, conn}

      {:error, conn, error, _responses} ->
        {:error, conn, error}
    end
  end

  defp collect_response({:status, ref, status}, {_state, acc}, ref) when status in 100..199,
    do: {:continue, %{acc | status: status}}

  defp collect_response({:status, ref, status}, {state, acc}, ref),
    do: {state_after(state), %{acc | status: status}}

  defp collect_response({:headers, ref, headers}, {state, %{status: status} = acc}, ref)
       when status >= 200,
       do: {state_after(state), %{acc | headers: acc.headers ++ headers}}

  defp collect_response({:data, ref, data}, {state, acc}, ref),
    do: {state_after(state), %{acc | body: [acc.body, data]}}

  defp collect_response({:done, ref}, {_state, acc}, ref), do: {:done, acc}
  defp collect_response(_other, state, _ref), do: state

  # A final response already in progress stays in progress after a 1xx was
  # seen earlier in the same batch of responses.
  defp state_after(:continue), do: :more
  defp state_after(state), do: state

  defp close_load_conn({:ok, conn, response}, _conn) do
    _ = Mint.HTTP.close(conn)
    {:ok, response}
  end

  defp close_load_conn({:error, conn, error}, _conn) do
    _ = Mint.HTTP.close(conn)
    {:error, error}
  end

  defp close_load_conn({:error, error}, conn) do
    _ = Mint.HTTP.close(conn)
    {:error, error}
  end

  defp load_result({:ok, %{status: status, headers: headers, body: body}}),
    do: {:ok, %{status: status, headers: headers, body: IO.iodata_to_binary(body)}}

  defp load_result({:error, %Mint.TransportError{reason: :timeout}}), do: {:error, :timeout}

  defp load_result({:error, %Mint.TransportError{reason: reason}}),
    do: {:error, {:connect_failed, reason}}

  defp load_result({:error, %Mint.HTTPError{reason: reason}}), do: {:error, {:http_error, reason}}
  defp load_result({:error, reason}), do: {:error, reason}

  defp method_name(method), do: method |> to_string() |> String.upcase()

  defp request_auth(%{config: %{user: user, password: password}}) do
    [{"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}]
  end

  defp request_auth(_request), do: []
end
