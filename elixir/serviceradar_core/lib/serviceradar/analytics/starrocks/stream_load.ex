defmodule ServiceRadar.Analytics.StarRocks.StreamLoad do
  @moduledoc """
  EventWriter destination for StarRocks Stream Load.

  HTTP 200 is not a successful persistence acknowledgement. The load JSON
  `Status` must be `Success`, loaded rows must match the payload, and filtered
  rows must be zero. Lost responses are reconciled by load label before ACK.
  """

  @success_status "Success"

  def persist(table, rows, opts \\ []) when is_binary(table) and is_list(rows) do
    http = Keyword.get(opts, :http, &default_http/1)
    config = Keyword.get(opts, :config, %{})
    label = Keyword.get(opts, :label) || load_label(table, rows)

    body = encode_json_rows(rows)
    request = stream_load_request(config, table, label, body, opts)
    request = maybe_override_url(request, Keyword.get(opts, :url))
    redirects = Keyword.get(opts, :redirects, 3)

    opts = opts |> Keyword.put(:table, table) |> Keyword.put(:label, label)

    case http.(request) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] and redirects > 0 ->
        case location_header(resp) do
          nil ->
            {:error, {:http_status, status, label}}

          location ->
            persist(
              table,
              rows,
              opts
              |> Keyword.put(:url, location)
              |> Keyword.put(:redirects, redirects - 1)
            )
        end

      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        interpret_load(response_body, label, length(rows), opts)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, label}}

      {:error, :timeout} ->
        reconcile_or_retry(label, table, length(rows), opts)

      {:error, reason} ->
        {:error, {reason, label}}
    end
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

  defp interpret_load(%{"Status" => "Publish Timeout"}, label, expected_count, opts) do
    reconcile_or_retry(label, Keyword.get(opts, :table, ""), expected_count, opts)
  end

  defp interpret_load(%{"Status" => "Label Already Exists"}, label, expected_count, opts) do
    reconcile_or_retry(label, Keyword.get(opts, :table, ""), expected_count, opts)
  end

  defp interpret_load(%{"Status" => status}, label, _expected_count, _opts) do
    {:error, {:load_status, status, label}}
  end

  defp interpret_load(_payload, label, _expected_count, _opts) do
    {:error, {:invalid_load_json, label}}
  end

  defp reconcile_or_retry(label, table, expected_count, opts) do
    http = Keyword.get(opts, :http, &default_http/1)
    config = Keyword.get(opts, :config, %{})
    request = state_request(config, label)

    case http.(request) do
      {:ok, %{body: body}} ->
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
          {"format", "json"},
          {"strip_outer_array", "true"},
          {"label", label}
        ] ++ partial_update_headers(opts),
      body: body,
      config: config
    }
  end

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

  defp state_request(config, label) do
    database = Map.get(config, :database, "serviceradar")
    fe = Map.get(config, :fe_http, "http://127.0.0.1:8030")

    %{
      method: :get,
      url: "#{fe}/api/#{database}/get_load_state?label=#{label}",
      headers: [],
      body: nil,
      config: config
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
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    url = String.to_charlist(request.url)

    headers =
      Enum.map(request.headers ++ request_auth(request), fn {key, value} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
      end)

    http_opts = [timeout: 60_000, connect_timeout: 5_000, autoredirect: true]
    opts = [body_format: :binary]

    result =
      case request.method do
        :get ->
          :httpc.request(:get, {url, headers}, http_opts, opts)

        method ->
          :httpc.request(
            method,
            {url, headers, ~c"application/json", request.body || ""},
            http_opts,
            opts
          )
      end

    case result do
      {:ok, {{_http, status, _reason}, resp_headers, body}} ->
        headers =
          Enum.map(resp_headers, fn {key, value} ->
            {to_string(key), to_string(value)}
          end)

        {:ok, %{status: status, headers: headers, body: IO.iodata_to_binary(body)}}

      {:error, {:failed_connect, _}} ->
        {:error, :connect_failed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_auth(%{config: %{user: user, password: password}}) do
    [{"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}]
  end

  defp request_auth(_request), do: []
end
