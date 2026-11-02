defmodule ServiceRadar.Edge.OutputContract do
  @moduledoc """
  An output contract as this installation admits it: the values core signs into a production
  capability for that contract.

  The contract reference comes from the installation's contract registry document
  (`ServiceRadar.Edge.ContractRegistryDocument`), the same document the agent gateway admits
  records against, so the two cannot disagree. The entry must be `active` and pin the durable
  bulk lane; anything else means core issues no authority for it, because the gateway would
  withhold every record signed against it.

  The per-record bounds belong to the contract's producer and are passed in by its caller
  (`ServiceRadar.Edge.SweepContract`, `ServiceRadar.Edge.MetricsBatchContract`).
  """

  alias ServiceRadar.Edge.ContractRegistryDocument

  @type t :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_bundle_sha256: <<_::256>>,
          registry_epoch: pos_integer(),
          registry_snapshot_sha256: <<_::256>>,
          cost_model_version: pos_integer(),
          max_projected_row_count: pos_integer(),
          max_projected_write_bytes: pos_integer()
        }

  @type bounds :: %{max_projected_rows: pos_integer(), write_bytes_per_row: pos_integer()}

  @doc "The named contract from the installation's configured registry document."
  @spec current({String.t(), pos_integer()}, bounds()) :: {:ok, t()} | {:error, term()}
  def current(ref, bounds) do
    from_document(
      Application.get_env(:serviceradar_core, :edge_record_contract_registry),
      ref,
      bounds
    )
  end

  @doc "The named contract from a registry document."
  @spec from_document(term(), {String.t(), pos_integer()}, bounds()) ::
          {:ok, t()} | {:error, term()}
  def from_document(raw, {_id, _version} = ref, %{
        max_projected_rows: rows,
        write_bytes_per_row: per_row
      }) do
    with {:ok, snapshot} <- ContractRegistryDocument.parse(raw),
         {:ok, entry} <- entry(snapshot, ref) do
      {:ok,
       %{
         contract_id: entry.contract_id,
         contract_version: entry.contract_version,
         contract_bundle_sha256: entry.contract_bundle_sha256,
         registry_epoch: snapshot.registry_epoch,
         registry_snapshot_sha256: snapshot.registry_snapshot_sha256,
         cost_model_version: entry.cost_model_version,
         max_projected_row_count: rows,
         max_projected_write_bytes: rows * per_row
       }}
    end
  end

  defp entry(%{contracts: contracts}, ref) do
    case Map.fetch(contracts, ref) do
      {:ok,
       %{
         state: :active,
         route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
         traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
       } = entry} ->
        {:ok, entry}

      {:ok, %{state: state}} when state != :active ->
        {:error, {:contract_not_active, state}}

      {:ok, _entry} ->
        {:error, :contract_lane}

      :error ->
        {:error, :contract_not_registered}
    end
  end
end
