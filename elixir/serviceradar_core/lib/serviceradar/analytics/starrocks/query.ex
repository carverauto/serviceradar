defmodule ServiceRadar.Analytics.StarRocks.Query do
  @moduledoc """
  HTTP SQL client for authorized StarRocks SRQL execution.

  Compiles stay in the SRQL dialect; this module only submits the produced SQL
  to a Frontend. Inject `:http` in tests. Missing FE connectivity is an error,
  never a silent PostgreSQL fallback.
  """

  alias ServiceRadar.Analytics.StarRocks

  @spec execute(String.t(), keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, term()}
  def execute(sql, opts \\ []) when is_binary(sql) do
    config = Keyword.get(opts, :config, client_config())
    http = Keyword.get(opts, :http, configured_http())
    request = sql_request(config, sql)

    case http.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_result(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:starrocks_http_status, status, body}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sql_request(config, sql) do
    database = Map.get(config, :database, "serviceradar")
    fe = Map.get(config, :fe_http, "http://127.0.0.1:8030")

    %{
      method: :post,
      url: "#{fe}/api/v1/catalogs/default_catalog/databases/#{database}/sql",
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"query" => sql}),
      config: config
    }
  end

  defp decode_result(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        decode_result(payload)

      {:error, _} ->
        decode_ndjson(body)
    end
  end

  defp decode_result(%{"data" => data} = payload) when is_list(data) do
    columns = column_names(Map.get(payload, "meta", []))
    result_from_columns_and_rows(columns, rows_from_data(data, columns))
  end

  defp decode_result(_payload), do: {:error, :starrocks_http_json}

  defp decode_ndjson(body) do
    objects =
      body
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, object} when is_map(object) -> [object]
          _ -> []
        end
      end)

    columns =
      Enum.find_value(objects, [], fn
        %{"meta" => meta} -> column_names(meta)
        _ -> nil
      end)

    rows =
      objects
      |> Enum.filter(&Map.has_key?(&1, "data"))
      |> Enum.flat_map(fn %{"data" => data} -> rows_from_data(data, columns) end)

    result_from_columns_and_rows(columns, rows)
  end

  defp column_names(meta) when is_list(meta) do
    Enum.map(meta, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> "col"
    end)
  end

  defp rows_from_data(data, columns) when is_list(data) do
    width = length(columns)

    cond do
      data == [] ->
        []

      is_list(hd(data)) ->
        data

      width > 0 and length(data) == width ->
        [data]

      true ->
        Enum.map(data, &List.wrap/1)
    end
  end

  defp rows_from_data(data, _columns), do: [List.wrap(data)]

  defp result_from_columns_and_rows(columns, rows) do
    {:ok,
     %Postgrex.Result{
       command: :select,
       columns: columns,
       rows: rows,
       num_rows: length(rows),
       connection_id: nil
     }}
  end

  defp configured_http do
    :serviceradar_core
    |> Application.get_env(StarRocks, [])
    |> Keyword.get(:query_http, &default_http/1)
  end

  defp client_config do
    env = Application.get_env(:serviceradar_core, StarRocks, [])

    %{
      fe_http: Keyword.get(env, :fe_http, "http://127.0.0.1:8030"),
      database: Keyword.get(env, :database, "serviceradar"),
      user: Keyword.get(env, :user, "root"),
      password: Keyword.get(env, :password, "")
    }
  end

  defp default_http(request) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    url = String.to_charlist(request.url)

    headers =
      Enum.map(request.headers ++ request_auth(request), fn {key, value} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
      end)

    http_opts = [timeout: 15_000, connect_timeout: 3_000, autoredirect: true]
    opts = [body_format: :binary]

    result =
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", request.body || ""},
        http_opts,
        opts
      )

    case result do
      {:ok, {{_http, status, _reason}, _resp_headers, body}} ->
        {:ok, %{status: status, body: IO.iodata_to_binary(body)}}

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
