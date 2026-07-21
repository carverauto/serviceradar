defmodule ServiceRadarAgentGateway.EdgeStreamProvisioner do
  @moduledoc """
  Provisions the installation-local JetStream data and DLQ streams for the edge
  result relay (unify-sweep-results-proto task 4.2).

  For each of the five delivery lanes it declares a disjoint, file-backed data
  stream (covering all 64 partition subjects via a single-token wildcard) and a
  separate class-preserving DLQ stream. Streams use `limits` retention with
  `discard: new` so a full stream refuses new publishes (back-pressure the sender)
  rather than silently dropping older durable data, and an explicit 512 KiB body
  limit plus a bounded NATS-header allowance.

  Stream declarations go over the `$JS.API.STREAM.CREATE.<name>` request/reply
  API using `ServiceRadar.NATS.Connection.request/3`, so no extra JetStream client
  dependency is required. The gateway advertises `edge-results:v1` only after all
  required streams are writable (task 3.1) -- `ensure_all/1` returns per-stream
  results the caller gates readiness on.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadarAgentGateway.EdgeRoute

  # 512 KiB encoded body plus a bounded header allowance.
  @max_msg_size 512 * 1024 + 64 * 1024

  @doc "Stream config maps for every lane's data and DLQ stream."
  @spec stream_configs() :: [map()]
  def stream_configs do
    Enum.flat_map(EdgeRoute.routable_lanes(), fn lane -> [data_config(lane), dlq_config(lane)] end)
  end

  @doc "Config for a lane's data stream."
  @spec data_config(EdgeRoute.lane()) :: map()
  def data_config(lane) do
    base_config(EdgeRoute.physical_stream(lane), data_wildcard(lane))
  end

  @doc "Config for a lane's DLQ stream. DLQ disables MaxAge so poison never expires silently."
  @spec dlq_config(EdgeRoute.lane()) :: map()
  def dlq_config(lane) do
    lane
    |> EdgeRoute.physical_dlq_stream()
    |> base_config(dlq_wildcard(lane))
    |> Map.put(:max_age, 0)
  end

  @doc """
  Ensures every edge stream exists. Returns `{:ok, [names]}` when all succeed, or
  `{:error, failures}` where each failure is `{name, reason}`.
  """
  @spec ensure_all(keyword()) :: {:ok, [String.t()]} | {:error, [{String.t(), term()}]}
  def ensure_all(opts \\ []) do
    conn = Keyword.get(opts, :connection, Connection)
    timeout = Keyword.get(opts, :receive_timeout, 5_000)

    results = Enum.map(stream_configs(), &ensure(conn, &1, timeout))

    case Enum.filter(results, &match?({:error, _, _}, &1)) do
      [] -> {:ok, Enum.map(results, fn {:ok, name} -> name end)}
      failures -> {:error, Enum.map(failures, fn {:error, name, reason} -> {name, reason} end)}
    end
  end

  @doc "Declares one stream via the JetStream API. Idempotent (create-or-verify)."
  @spec ensure(module(), map(), non_neg_integer()) :: {:ok, String.t()} | {:error, String.t(), term()}
  def ensure(conn, %{name: name} = config, timeout \\ 5_000) do
    subject = "$JS.API.STREAM.CREATE.#{name}"

    case conn.request(subject, Jason.encode!(config), receive_timeout: timeout) do
      {:ok, %{body: body}} -> parse_create(body, name)
      {:error, reason} -> {:error, name, reason}
    end
  end

  @doc "Parses a `$JS.API.STREAM.CREATE` response body."
  @spec parse_create(binary(), String.t()) :: {:ok, String.t()} | {:error, String.t(), term()}
  def parse_create(body, name) when is_binary(body) do
    case Jason.decode(body) do
      # A pre-existing stream with matching config is reported via an error whose
      # code indicates "stream name already in use"; treat an existing stream as
      # success only when the returned config matches, otherwise surface it.
      {:ok, %{"error" => %{"err_code" => 10_058}}} -> {:ok, name}
      {:ok, %{"error" => error}} -> {:error, name, error}
      {:ok, %{"config" => _config}} -> {:ok, name}
      {:ok, other} -> {:error, name, {:unexpected_response, other}}
      {:error, _} -> {:error, name, :invalid_json}
    end
  end

  # --- config builders ---

  defp base_config(name, subject_wildcard) do
    %{
      name: name,
      subjects: [subject_wildcard],
      retention: "limits",
      discard: "new",
      storage: "file",
      num_replicas: 1,
      max_msg_size: @max_msg_size
    }
  end

  # data_subject(lane, 0) => "sr.edge.v1.<tok>.p00.v1"; the partition token
  # becomes a single-token wildcard so one stream covers all 64 partitions.
  defp data_wildcard(lane), do: String.replace(EdgeRoute.data_subject(lane, 0), ".p00.", ".*.")
  defp dlq_wildcard(lane), do: String.replace(EdgeRoute.dlq_subject(lane, 0), ".p00.", ".*.")
end
