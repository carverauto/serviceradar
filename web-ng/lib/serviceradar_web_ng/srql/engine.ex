defmodule ServiceRadarWebNG.SRQL.Engine do
  @moduledoc false

  use GenServer

  require Logger

  alias ServiceRadarWebNG.SRQL.Native

  @default_timeout_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def query(%{} = request) do
    GenServer.call(__MODULE__, {:query, request}, @default_timeout_ms)
  end

  @impl true
  def init(_opts) do
    {:ok, %{engine: nil}}
  end

  @impl true
  def handle_call({:query, request}, _from, state) do
    with {:ok, engine, next_state} <- ensure_engine(state),
         {:ok, query, limit, cursor, direction, mode} <- normalize_request(request),
         {:ok, json} <- do_query(engine, query, limit, cursor, direction, mode),
         {:ok, decoded} <- Jason.decode(json) do
      {:reply, {:ok, decoded}, next_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_engine(%{engine: engine} = state) when not is_nil(engine) do
    {:ok, engine, state}
  end

  defp ensure_engine(state) do
    {database_url, root_cert, client_cert, client_key, pool_size} = srql_db_config()

    case Native.init(database_url, root_cert, client_cert, client_key, pool_size) do
      {:ok, engine} ->
        Logger.info("SRQL engine initialized")
        next_state = %{state | engine: engine}
        {:ok, engine, next_state}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp do_query(engine, query, limit, cursor, direction, mode) do
    case Native.query(engine, query, limit, cursor, direction, mode) do
      {:ok, json} when is_binary(json) -> {:ok, json}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp normalize_request(%{"query" => query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, "limit"))
    cursor = normalize_optional_string(Map.get(request, "cursor"))
    direction = normalize_direction(Map.get(request, "direction"))
    mode = normalize_optional_string(Map.get(request, "mode"))
    {:ok, query, limit, cursor, direction, mode}
  end

  defp normalize_request(%{query: query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, :limit))
    cursor = normalize_optional_string(Map.get(request, :cursor))
    direction = normalize_direction(Map.get(request, :direction))
    mode = normalize_optional_string(Map.get(request, :mode))
    {:ok, query, limit, cursor, direction, mode}
  end

  defp normalize_request(_request) do
    {:error, "missing required field: query"}
  end

  defp parse_limit(nil), do: nil
  defp parse_limit(limit) when is_integer(limit), do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_direction(nil), do: nil

  defp normalize_direction(direction) when direction in ["next", "prev"] do
    direction
  end

  defp normalize_direction(direction) when direction in [:next, :prev] do
    Atom.to_string(direction)
  end

  defp normalize_direction(_direction), do: nil

  defp srql_db_config do
    config = ServiceRadarWebNG.Repo.config()

    username = Keyword.get(config, :username)
    password = Keyword.get(config, :password)
    hostname = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port, 5432)
    database = Keyword.get(config, :database)

    userinfo =
      case {username, password} do
        {nil, _} ->
          nil

        {user, nil} ->
          URI.encode_www_form(to_string(user))

        {user, pass} ->
          "#{URI.encode_www_form(to_string(user))}:#{URI.encode_www_form(to_string(pass))}"
      end

    database_url =
      %URI{
        scheme: "postgres",
        userinfo: userinfo,
        host: to_string(hostname),
        port: port,
        path: "/" <> to_string(database || "")
      }
      |> URI.to_string()

    ssl = Keyword.get(config, :ssl, false)

    {root_cert, client_cert, client_key} =
      if is_list(ssl) do
        {
          Keyword.get(ssl, :cacertfile),
          Keyword.get(ssl, :certfile),
          Keyword.get(ssl, :keyfile)
        }
      else
        {nil, nil, nil}
      end

    pool_size = Keyword.get(config, :pool_size, 10)
    {database_url, root_cert, client_cert, client_key, pool_size}
  end
end
