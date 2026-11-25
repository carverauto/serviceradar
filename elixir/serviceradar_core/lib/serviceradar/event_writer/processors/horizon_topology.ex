defmodule ServiceRadar.EventWriter.Processors.HorizonTopology do
  @moduledoc """
  Fail-open CQRS projector for Horizon external Internet topology snapshots
  (`serviceradar.horizon.topology.snapshot`) and outage/BGP state updates
  (`serviceradar.horizon.outages.>`, `serviceradar.horizon.bgp.>`).
  """

  alias ServiceRadar.Dgraph.TransientError
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjection

  require Logger

  @snapshot_subject "serviceradar.horizon.topology.snapshot"

  @doc """
  Processes a single NATS JetStream message for Horizon topology subjects.

  Returns `:ok` on success, ignored/malformed messages, or disabled graph store
  (fail-open). Returns `{:error, :transient}` only on retryable graph-store
  errors when `final_delivery?: false`.
  """
  @spec process_message(String.t(), binary(), keyword()) :: :ok | {:error, :transient}
  def process_message(subject, payload, opts \\ [])

  def process_message(subject, payload, opts) when is_binary(subject) and is_binary(payload) do
    if supported_subject?(subject) do
      case Jason.decode(payload) do
        {:ok, decoded} when is_map(decoded) ->
          dispatch_decoded(subject, decoded, opts)

        {:ok, _other} ->
          Logger.warning("HorizonTopology ignored non-object payload on #{subject}")
          :ok

        {:error, reason} ->
          Logger.warning(
            "HorizonTopology dropped malformed JSON on #{subject}: #{Exception.message(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "HorizonTopology failed on #{subject} (fail-open): #{Exception.message(error)}"
      )

      :ok
  end

  def process_message(_subject, _payload, _opts), do: :ok

  @doc """
  Returns true if `subject` belongs to the Horizon topology projection stream.
  """
  @spec supported_subject?(String.t()) :: boolean()
  def supported_subject?(@snapshot_subject), do: true
  def supported_subject?("serviceradar.horizon.outages." <> _), do: true
  def supported_subject?("serviceradar.horizon.bgp." <> _), do: true
  def supported_subject?(_), do: false

  defp dispatch_decoded(@snapshot_subject, decoded, opts) do
    case ExternalProjection.normalize_snapshot(decoded) do
      {:ok, snapshot} ->
        apply_store_call(
          fn -> store_fun(opts, :upsert_external_topology).(snapshot, opts) end,
          opts,
          @snapshot_subject
        )

      {:ignore, :raw_per_round_hops} ->
        Logger.debug("HorizonTopology rejected raw per-round hop payload on snapshot subject")
        :ok

      {:error, reason} ->
        Logger.warning("HorizonTopology dropped invalid snapshot: #{inspect(reason)}")
        :ok
    end
  end

  defp dispatch_decoded(subject, decoded, opts) do
    case ExternalProjection.normalize_status_event(subject, decoded) do
      {:ok, patch} ->
        apply_store_call(
          fn -> store_fun(opts, :upsert_external_status).(patch, opts) end,
          opts,
          subject
        )

      {:ignore, :unmatched_event} ->
        :ok
    end
  end

  defp apply_store_call(fun, opts, subject) do
    case fun.() do
      :ok ->
        :ok

      {:ok, _stats} ->
        :ok

      {:error, %TransientError{} = err} ->
        handle_transient(err, opts, subject)

      {:error, :transient} ->
        handle_transient(:transient, opts, subject)

      {:error, reason} ->
        Logger.warning(
          "HorizonTopology store error on #{subject} (fail-open): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp handle_transient(reason, opts, subject) do
    if Keyword.get(opts, :final_delivery?, false) do
      Logger.warning(
        "HorizonTopology final delivery transient error on #{subject} (fail-open): #{inspect(reason)}"
      )

      :ok
    else
      {:error, :transient}
    end
  end

  defp store_fun(opts, key) do
    case Keyword.get(opts, key) do
      fun when is_function(fun, 2) -> fun
      _ -> fn arg, call_opts -> apply(TopologyGraph, key, [arg, call_opts]) end
    end
  end
end
