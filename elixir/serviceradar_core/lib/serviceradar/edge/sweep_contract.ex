defmodule ServiceRadar.Edge.SweepContract do
  @moduledoc """
  The sweep observation output contract as this installation admits it: the values core signs
  into a sweep lease's production capability.

  The contract reference comes from the installation's contract registry document
  (`ServiceRadar.Edge.ContractRegistryDocument`), the same document the agent gateway admits
  records against, so the two cannot disagree. The entry must be `active` and pin the durable
  bulk lane sweep records travel on; anything else means core issues no lease authority, because
  the gateway would withhold every record signed against it.

  The per-record bounds are the sweep contract's own. A batch projects one reachability row
  per host plus one row per open port and per port error, plus an MTR summary
  (`projection.SweepProjectionRows`, `obsbatch.hostCost`). The ceiling is
  `obsbatch.DefaultMaxSweepRows` (10000) projected rows per batch, with a 2 KiB write budget
  per projected row.
  """

  alias ServiceRadar.Edge.ContractRegistryDocument

  @contract_id "serviceradar.sweep.observation"
  @contract_version 1
  @max_projected_rows 10_000
  @write_bytes_per_row 2_048

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

  @doc "The configured sweep contract, or why core cannot sign against it."
  @spec current() :: {:ok, t()} | {:error, term()}
  def current do
    from_document(Application.get_env(:serviceradar_core, :edge_record_contract_registry))
  end

  @doc "The sweep contract named by a registry document."
  @spec from_document(term()) :: {:ok, t()} | {:error, term()}
  def from_document(raw) do
    with {:ok, snapshot} <- ContractRegistryDocument.parse(raw),
         {:ok, entry} <- entry(snapshot) do
      {:ok,
       %{
         contract_id: entry.contract_id,
         contract_version: entry.contract_version,
         contract_bundle_sha256: entry.contract_bundle_sha256,
         registry_epoch: snapshot.registry_epoch,
         registry_snapshot_sha256: snapshot.registry_snapshot_sha256,
         cost_model_version: entry.cost_model_version,
         max_projected_row_count: @max_projected_rows,
         max_projected_write_bytes: @max_projected_rows * @write_bytes_per_row
       }}
    end
  end

  defp entry(%{contracts: contracts}) do
    case Map.fetch(contracts, {@contract_id, @contract_version}) do
      {:ok,
       %{
         state: :active,
         route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
         traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
       } = entry} ->
        {:ok, entry}

      {:ok, %{state: state}} when state != :active ->
        {:error, {:sweep_contract_not_active, state}}

      {:ok, _entry} ->
        {:error, :sweep_contract_lane}

      :error ->
        {:error, :sweep_contract_not_registered}
    end
  end
end
