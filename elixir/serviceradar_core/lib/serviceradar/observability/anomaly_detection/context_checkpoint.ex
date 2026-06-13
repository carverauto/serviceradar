defmodule ServiceRadar.Observability.AnomalyDetection.ContextCheckpoint do
  @moduledoc """
  JetStream KV persistence for per-series anomaly context snapshots.
  """

  alias Jetstream.API.Stream

  @default_bucket "serviceradar_anomaly_context"
  @default_history 1
  @default_storage :file
  @default_replicas 1

  require Logger

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

  @spec save(String.t(), map(), keyword()) :: :ok | {:ok, non_neg_integer()} | {:error, term()}
  def save(series_key, snapshot, opts \\ []) when is_binary(series_key) and is_map(snapshot) do
    with_config(opts, fn config ->
      if Keyword.get(config, :enabled, false) do
        with_connection(config, fn conn ->
          with :ok <- ensure_bucket(conn, config),
               {:ok, encoded} <- Jason.encode(snapshot) do
            write_checkpoint(conn, config, checkpoint_key(series_key), encoded)
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
    case stream_api(config).get_message(conn, "KV_#{bucket(config)}", %{
           last_by_subj: key_subject(bucket(config), key)
         }) do
      {:ok, %{data: value, seq: revision}} when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{} = decoded} -> {:ok, Map.put(decoded, :__checkpoint_revision__, revision)}
          {:ok, _other} -> {:error, :invalid_checkpoint_payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, %{"code" => 404}} ->
        {:ok, nil}

      {:error, %{code: 404}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_checkpoint(conn, config, key, encoded) do
    opts =
      config
      |> kv_opts()
      |> Keyword.take([:timeout, :receive_timeout])
      |> Keyword.put_new(:receive_timeout, Keyword.get(kv_opts(config), :timeout, 5_000))
      |> put_expected_revision_header(Keyword.get(config, :expected_revision))

    case request_api(config).request(conn, key_subject(bucket(config), key), encoded, opts) do
      {:ok, %{status: status} = response} when status in ["400", "409"] ->
        {:error, classify_write_error(response)}

      {:ok, %{body: body}} ->
        parse_pub_ack(body)

      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_expected_revision_header(opts, revision) when is_integer(revision) and revision >= 0 do
    Keyword.update(
      opts,
      :headers,
      [{"Nats-Expected-Last-Subject-Sequence", Integer.to_string(revision)}],
      &[{"Nats-Expected-Last-Subject-Sequence", Integer.to_string(revision)} | &1]
    )
  end

  defp put_expected_revision_header(opts, _revision), do: opts

  defp parse_pub_ack(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"seq" => revision}} when is_integer(revision) -> {:ok, revision}
      {:ok, %{"error" => error}} -> {:error, classify_write_error(error)}
      {:ok, ack} ->
        Logger.warning("anomaly context checkpoint PubAck missing sequence",
          ack: inspect(ack)
        )

        :ok

      {:error, reason} ->
        Logger.warning("anomaly context checkpoint PubAck decode failed",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp parse_pub_ack(body) do
    Logger.warning("anomaly context checkpoint PubAck missing body",
      body: inspect(body)
    )

    :ok
  end

  defp classify_write_error(%{"description" => description}) when is_binary(description) do
    classify_write_error(description)
  end

  defp classify_write_error(%{description: description}) when is_binary(description) do
    classify_write_error(description)
  end

  defp classify_write_error(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> classify_write_error(error)
      _ -> body
    end
  end

  defp classify_write_error(description) when is_binary(description) do
    normalized = String.downcase(description)

    if String.contains?(normalized, "wrong last") or
         String.contains?(normalized, "expected") or
         String.contains?(normalized, "sequence") do
      :checkpoint_revision_conflict
    else
      description
    end
  end

  defp classify_write_error(reason), do: reason

  defp ensure_bucket(conn, config) do
    if Keyword.get(config, :ensure_bucket, true) do
      cache_key = bucket_cache_key(config)

      if :persistent_term.get(cache_key, false) do
        :ok
      else
        case ensure_bucket_uncached(conn, config) do
          :ok ->
            :persistent_term.put(cache_key, true)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      :ok
    end
  end

  defp ensure_bucket_uncached(conn, config) do
    stream = "KV_#{bucket(config)}"

    case stream_api(config).info(conn, stream) do
      {:ok, _info} -> :ok
      {:error, %{"code" => 404}} -> create_bucket(conn, config)
      {:error, %{code: 404}} -> create_bucket(conn, config)
      {:error, reason} -> {:error, reason}
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

  defp key_subject(bucket, key), do: "$KV.#{bucket}.#{key}"

  defp bucket_cache_key(config) do
    {__MODULE__, :bucket_ready, bucket(config), stream_api(config), kv(config),
     bucket_opts(config)}
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp connection(config), do: Keyword.get(config, :connection, ServiceRadar.NATS.Connection)

  defp kv(config), do: Keyword.get(config, :kv, Jetstream.API.KV)

  defp stream_api(config), do: Keyword.get(config, :stream_api, Stream)

  defp request_api(config), do: Keyword.get(config, :request_api, Gnat)
end
