defmodule ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint do
  @moduledoc """
  JetStream KV persistence for per-series anomaly context snapshots.
  """

  alias Jetstream.API.Stream

  @default_bucket "serviceradar_anomaly_context"
  @default_history 1
  @default_storage :file
  @default_replicas 1

  @spec load(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def load(series_key, opts \\ []) when is_binary(series_key) do
    with_config(opts, fn config ->
      if Keyword.get(config, :enabled, false) do
        with_connection(config, fn conn ->
          with :ok <- ensure_bucket(conn, config) do
            read_checkpoint(conn, config, checkpoint_key(series_key))
          end
        end)
      else
        {:ok, nil}
      end
    end)
  end

  @spec save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(series_key, snapshot, opts \\ []) when is_binary(series_key) and is_map(snapshot) do
    with_config(opts, fn config ->
      if Keyword.get(config, :enabled, false) do
        with_connection(config, fn conn ->
          with :ok <- ensure_bucket(conn, config),
               {:ok, encoded} <- Jason.encode(snapshot) do
            kv(config).put_value(
              conn,
              bucket(config),
              checkpoint_key(series_key),
              encoded,
              kv_opts(config)
            )
          end
        end)
      else
        :ok
      end
    end)
  end

  @spec checkpoint_key(String.t()) :: String.t()
  def checkpoint_key(series_key) when is_binary(series_key) do
    "series/#{Base.url_encode64(series_key, padding: false)}"
  end

  defp read_checkpoint(conn, config, key) do
    case kv(config).get_value(conn, bucket(config), key) do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          {:ok, _other} -> {:error, :invalid_checkpoint_payload}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:ok, nil}

      {:error, %{"code" => 404}} ->
        {:ok, nil}

      {:error, %{code: 404}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_bucket(conn, config) do
    if Keyword.get(config, :ensure_bucket, true) do
      stream = "KV_#{bucket(config)}"

      case stream_api(config).info(conn, stream) do
        {:ok, _info} -> :ok
        {:error, %{"code" => 404}} -> create_bucket(conn, config)
        {:error, %{code: 404}} -> create_bucket(conn, config)
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp create_bucket(conn, config) do
    case kv(config).create_bucket(conn, bucket(config), bucket_opts(config)) do
      {:ok, _info} ->
        :ok

      {:error, %{"code" => 400, "description" => description}} ->
        maybe_already_exists(description)

      {:error, %{code: 400, description: description}} ->
        maybe_already_exists(description)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_already_exists(description) when is_binary(description) do
    if String.contains?(String.downcase(description), "already") do
      :ok
    else
      {:error, description}
    end
  end

  defp maybe_already_exists(reason), do: {:error, reason}

  defp with_connection(config, fun) do
    case connection(config).get() do
      {:ok, conn} -> fun.(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_config(opts, fun) do
    config()
    |> Keyword.merge(opts)
    |> fun.()
  end

  defp bucket(config), do: Keyword.get(config, :bucket, @default_bucket)

  defp bucket_opts(config) do
    ttl_seconds = Keyword.get(config, :ttl_seconds, 0)
    ttl = if ttl_seconds > 0, do: ttl_seconds * 1_000_000_000, else: 0

    Enum.reject(
      [
        description:
          Keyword.get(config, :description, "ServiceRadar anomaly context checkpoints"),
        history: Keyword.get(config, :history, @default_history),
        ttl: ttl,
        max_bucket_size: Keyword.get(config, :max_bucket_size),
        max_value_size: Keyword.get(config, :max_value_size),
        replicas: Keyword.get(config, :replicas, @default_replicas),
        storage: Keyword.get(config, :storage, @default_storage)
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp kv_opts(config), do: Keyword.get(config, :kv_opts, [])

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp connection(config), do: Keyword.get(config, :connection, ServiceRadar.NATS.Connection)

  defp kv(config), do: Keyword.get(config, :kv, Jetstream.API.KV)

  defp stream_api(config), do: Keyword.get(config, :stream_api, Stream)
end
