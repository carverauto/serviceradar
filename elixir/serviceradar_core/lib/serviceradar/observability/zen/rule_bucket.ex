defmodule ServiceRadar.Observability.Zen.RuleBucket do
  @moduledoc """
  The NATS key-value bucket collectors read their Zen rule bundles from.

  The bucket holds rule bundles and nothing else, so a collector's NATS user
  can read and watch it without reaching agent configuration or any other
  key-value data, which share the datasvc bucket. `ZenRuleSync` writes every
  bundle here under the key `RuleBundle.kv_key/2` names, beside the datasvc
  write that collectors without a NATS reader still use.

  Each key keeps only its latest bundle, values never expire and the bucket is
  file-backed. The NATS account requires every stream to declare a finite
  size, so the bucket has a cap (`:max_bytes`, 1 MiB unless
  `SERVICERADAR_JS_KV_SERVICERADAR_ZEN_RULES_MAX_BYTES` sets it) and a
  replica count (`:replicas`, from `SERVICERADAR_JS_KV_SERVICERADAR_ZEN_RULES_REPLICAS`,
  which the chart sets to the datasvc bucket's).

  `ensure/0` creates the bucket when it is missing and applies the configured
  cap; core's reconcile runs it. `put/2` only writes, so a node that saves a
  rule before the bucket exists gets an error, and the next reconcile writes
  the bundle, instead of that node creating the bucket with its own settings.
  """

  alias Gnat.Jetstream.API.KV
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.NATS.StateBucketSizing

  @bucket "serviceradar-zen-rules"
  @stream "KV_" <> @bucket
  @default_max_bytes 1_048_576
  @default_replicas 1
  @request_timeout_ms 5_000
  # JetStream's default duplicate window; a KV bucket keeps it when values never expire.
  @duplicate_window_ns 120_000_000_000

  @doc "The bucket name. Collectors default to it and NATS grants name its stream."
  @spec bucket() :: String.t()
  def bucket, do: @bucket

  @doc "The bucket cap when none is configured."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "The replica count when none is configured."
  @spec default_replicas() :: pos_integer()
  def default_replicas, do: @default_replicas

  @doc """
  Creates the bucket when it is missing, or applies the configured cap to it.
  """
  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    with_connection(fn conn ->
      request = fn subject, payload -> jetstream_request(conn, subject, payload) end

      case StateBucketSizing.ensure(request, stream_name(), stream_config(), max_bytes()) do
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Writes `payload` under `key` and returns once the bucket stored it. A write
  the broker denies, or the bucket refuses, is an error.
  """
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, payload) when is_binary(key) and is_binary(payload) do
    case JetStreamPublish.publish_acked("$KV.#{@bucket}.#{key}", payload,
           timeout: @request_timeout_ms
         ) do
      {:ok, %{stream: @stream, seq: seq}} when seq > 0 -> :ok
      # A write the stream refuses (its cap is full) is answered with the
      # stream's name, sequence 0 and an error, which reads as an ack here.
      {:ok, %{stream: @stream}} -> {:error, :not_stored}
      {:ok, %{stream: stream}} -> {:error, {:stored_by_other_stream, stream}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:nats_connection_died, reason}}
  end

  @doc """
  Lists the keys the bucket holds a bundle under.
  """
  @spec keys() :: {:ok, [String.t()]} | {:error, term()}
  def keys do
    with_connection(&KV.keys(&1, @bucket))
  end

  defp stream_name, do: @stream

  # The stream `Gnat.Jetstream.API.KV.create_bucket/3` defines for one value of
  # history and no TTL, plus `allow_direct`, which KV readers use for gets.
  defp stream_config do
    %{
      name: stream_name(),
      subjects: ["$KV.#{@bucket}.>"],
      description: "Zen rule bundles collectors follow",
      max_msgs_per_subject: 1,
      discard: :new,
      deny_delete: true,
      allow_rollup_hdrs: true,
      allow_direct: true,
      max_age: 0,
      max_msg_size: -1,
      max_msgs: -1,
      max_consumers: -1,
      num_replicas: replicas(),
      retention: :limits,
      storage: :file,
      duplicate_window: @duplicate_window_ns
    }
  end

  defp max_bytes, do: Keyword.get(config(), :max_bytes, @default_max_bytes)
  defp replicas, do: Keyword.get(config(), :replicas, @default_replicas)
  defp config, do: Application.get_env(:serviceradar_core, __MODULE__, [])

  defp jetstream_request(conn, subject, payload) do
    with {:ok, %{body: body}} <-
           Gnat.request(conn, subject, payload, receive_timeout: @request_timeout_ms),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"error" => error} -> {:error, error}
        reply -> {:ok, reply}
      end
    end
  end

  defp with_connection(fun) do
    case Connection.get() do
      {:ok, conn} ->
        try do
          fun.(conn)
        catch
          :exit, reason -> {:error, {:nats_connection_died, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
