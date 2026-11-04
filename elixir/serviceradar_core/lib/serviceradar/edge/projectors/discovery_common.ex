defmodule ServiceRadar.Edge.Projectors.DiscoveryCommon do
  @moduledoc """
  Shared pieces of the discovery projectors (mapper, netprobe, sync pages):
  the standing-grant re-check every projector performs before projecting,
  the sync-ingestion scheduling the legacy result router used, and the
  small map/timestamp helpers that rebuild the legacy JSON update payloads
  from the typed batches.
  """

  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Inventory.SyncIngestorQueue

  @doc """
  Re-checks the record's standing grant and runs `fun` when it is current.
  A grant that is not current refuses the record; any other lookup error
  fails the batch so the record is redelivered.
  """
  @spec with_current_grant(EdgeRecordV1.t(), (String.t() -> :ok | {:error, term()})) ::
          :ok | {:refused, term()} | {:error, term()}
  def with_current_grant(%EdgeRecordV1{} = record, fun) do
    context = record.producer_context
    agent_id = context.origin_principal_id

    case OutputGrants.check_current(
           Ecto.UUID.load!(context.producer_assignment_id),
           agent_id,
           record.output_contract.contract_id,
           Ecto.UUID.load!(record.network_scope_id),
           context.authority_epoch
         ) do
      :ok -> fun.(agent_id)
      {:error, :output_grant_not_current} -> {:refused, :output_grant_not_current}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Hands a rebuilt legacy JSON payload to the sync ingestion pipeline the
  same way `ServiceRadar.Ingestion.ResultIngestor.schedule_sync_ingestion/1`
  does: queued when async ingestion is enabled, inline otherwise.
  """
  @spec schedule_sync_ingestion(binary()) :: :ok | {:error, term()}
  def schedule_sync_ingestion(message) do
    if Application.get_env(:serviceradar_core, :sync_ingestor_async, true) do
      case SyncIngestorQueue.enqueue(message) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      case SyncIngestorQueue.ingest_sync_results(message) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Encodes rebuilt update maps as the JSON array payload the legacy path sent."
  @spec encode_updates([map()]) :: binary()
  def encode_updates(updates), do: Jason.encode!(updates)

  @doc "Drops nil and empty-string values, keeping false and zero."
  @spec compact(map()) :: map()
  def compact(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  @doc "Puts `key => value` unless the value is nil, empty, or an empty collection."
  @spec put_present(map(), String.t(), term()) :: map()
  def put_present(map, _key, value) when value in [nil, "", [], %{}], do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Unix nanoseconds as an RFC3339 timestamp, or nil when unset."
  @spec iso8601(integer() | nil) :: String.t() | nil
  def iso8601(nanos) when is_integer(nanos) and nanos > 0 do
    nanos
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.to_iso8601()
  end

  def iso8601(_nanos), do: nil

  @doc "Unix nanoseconds as an RFC3339 timestamp truncated to one second (the sync wire form)."
  @spec iso8601_second(integer() | nil) :: String.t() | nil
  def iso8601_second(nanos) when is_integer(nanos) and nanos > 0 do
    nanos
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def iso8601_second(_nanos), do: nil

  @doc false
  @spec check(boolean(), term()) :: :ok | {:error, term()}
  def check(true, _reason), do: :ok
  def check(false, reason), do: {:error, reason}

  @doc false
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false
end
