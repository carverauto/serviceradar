defmodule ServiceRadar.Observability.ThreatIntelRawPayloadStore do
  @moduledoc """
  NATS Object Store backend for raw threat-intel provider payload snapshots.
  """

  alias Jetstream.API.Object

  @default_bucket "serviceradar_threat_intel"

  @spec put_page(map(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put_page(%{} = metadata, payload) when is_binary(payload) do
    object_key = object_key(metadata, payload)

    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, io} <- StringIO.open(payload),
           {:ok, _meta} <- Object.put(conn, bucket_name(), object_key, io) do
        {:ok, object_key}
      end
    end)
  end

  def put_page(_metadata, _payload), do: {:error, :invalid_payload}

  @spec object_key(map(), binary()) :: String.t()
  def object_key(%{} = metadata, payload) when is_binary(payload) do
    source = metadata |> Map.get(:source, "unknown") |> safe_path_segment()
    collection = metadata |> Map.get(:collection_id, "default") |> safe_path_segment()
    observed_at = metadata |> Map.get(:observed_at) |> timestamp_segment()
    hash = sha256(payload)

    "#{source}/#{collection}/#{observed_at}-#{hash}.json"
  end

  @spec sha256(binary()) :: String.t()
  def sha256(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp bucket_name do
    Keyword.get(config(), :jetstream_bucket, @default_bucket)
  end

  defp bucket_opts do
    ttl_seconds = Keyword.get(config(), :jetstream_ttl_seconds, 0)
    ttl_ns = if ttl_seconds > 0, do: ttl_seconds * 1_000_000_000, else: 0

    Enum.reject(
      [
        description:
          Keyword.get(config(), :jetstream_description, "Threat-intel raw payload snapshots"),
        max_bucket_size: Keyword.get(config(), :jetstream_max_bucket_size),
        max_chunk_size: Keyword.get(config(), :jetstream_max_chunk_size),
        replicas: Keyword.get(config(), :jetstream_replicas, 1),
        storage: Keyword.get(config(), :jetstream_storage, :file),
        ttl: ttl_ns
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp with_jetstream(fun) when is_function(fun, 1) do
    case ServiceRadar.NATS.Connection.get() do
      {:ok, conn} -> fun.(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_bucket(conn) do
    stream_name = "OBJ_#{bucket_name()}"

    case Jetstream.API.Stream.info(conn, stream_name) do
      {:ok, _} ->
        {:ok, :exists}

      {:error, %{"code" => 404}} ->
        create_bucket(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_bucket(conn) do
    stream_name = "OBJ_#{bucket_name()}"

    with {:ok, %{body: body}} <-
           Gnat.request(
             conn,
             "$JS.API.STREAM.CREATE.#{stream_name}",
             Jason.encode!(bucket_stream_config())
           ),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"error" => reason} -> {:error, reason}
        response -> {:ok, response}
      end
    end
  end

  defp bucket_stream_config do
    opts = bucket_opts()
    ttl = Keyword.get(opts, :ttl, 0)

    [
      name: "OBJ_#{bucket_name()}",
      subjects: ["$O.#{bucket_name()}.C.>", "$O.#{bucket_name()}.M.>"],
      description: Keyword.get(opts, :description),
      discard: :new,
      allow_rollup_hdrs: true,
      max_age: ttl,
      max_bytes: Keyword.get(opts, :max_bucket_size, -1),
      max_msg_size: Keyword.get(opts, :max_chunk_size, -1),
      max_consumers: -1,
      max_msgs: -1,
      max_msgs_per_subject: -1,
      num_replicas: Keyword.get(opts, :replicas, 1),
      retention: :limits,
      storage: Keyword.get(opts, :storage, :file),
      duplicate_window: duplicate_window_for_ttl(ttl)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @two_minutes_in_nanoseconds 1_200_000_000
  defp duplicate_window_for_ttl(ttl) when ttl > 0 and ttl < @two_minutes_in_nanoseconds, do: ttl
  defp duplicate_window_for_ttl(_ttl), do: @two_minutes_in_nanoseconds

  defp safe_path_segment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.:-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      segment -> segment
    end
  end

  defp safe_path_segment(_value), do: "unknown"

  defp timestamp_segment(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]+/, "")
  end

  defp timestamp_segment(_value), do: timestamp_segment(DateTime.utc_now())
end
