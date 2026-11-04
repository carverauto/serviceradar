defmodule ServiceRadar.Edge.OutputContract do
  @moduledoc """
  An output contract as this installation admits it: the values core signs into a production
  capability for that contract.

  The contract reference is the active registry epoch's entry
  (`ServiceRadar.Edge.ContractRegistry.active_epoch/0`), the epoch every gateway admits records
  under, so the two cannot disagree. Core signs it only when:

    * the entry pins the durable bulk lane, because the gateway would withhold any other record
      signed against it; and
    * this node's own catalog holds the entry's exact bundle digest. A node never authorizes
      production of records under a bundle it does not hold, so a node on a newer or older
      release signs only the entries its release shares with the active epoch.

  The per-record bounds are the contract's catalog entry (`ServiceRadar.Edge.ContractCatalog`);
  the matching bundle digest proves the active epoch carries the same bounds.
  """

  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistry

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

  @doc "The named contract under the active registry epoch."
  @spec current(ContractCatalog.ref()) :: {:ok, t()} | {:error, term()}
  def current(ref) do
    with {:ok, epoch} <- ContractRegistry.active_epoch() do
      from_epoch(epoch, ref)
    end
  end

  @doc """
  The named contract under a verified registry epoch, signed only when this node's catalog holds
  the entry's exact bundle (`ServiceRadar.Edge.ContractBundle.local/0`).
  """
  @spec from_epoch(map(), ContractCatalog.ref(), ContractBundle.local()) ::
          {:ok, t()} | {:error, term()}
  def from_epoch(epoch, ref, local \\ ContractBundle.local()) do
    with {:ok, %{max_projected_rows: rows, write_bytes_per_row: per_row} = cat} <- catalog(ref),
         {:ok, entry} <- entry(epoch, ref),
         :ok <- held(entry, local) do
      {:ok,
       %{
         contract_id: entry.contract_id,
         contract_version: entry.contract_version,
         contract_bundle_sha256: entry.contract_bundle_sha256,
         registry_epoch: epoch.epoch,
         registry_snapshot_sha256: epoch.snapshot_sha256,
         cost_model_version: entry.cost_model_version,
         max_projected_row_count: rows,
         max_projected_write_bytes:
           Map.get_lazy(cat, :max_projected_write_bytes, fn -> rows * per_row end)
       }}
    end
  end

  defp catalog(ref) do
    case ContractCatalog.fetch(ref) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :contract_not_cataloged}
    end
  end

  defp entry(%{contracts: contracts}, ref) do
    case Map.fetch(contracts, ref) do
      {:ok,
       %{
         route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
         traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
       } = entry} ->
        {:ok, entry}

      {:ok, _entry} ->
        {:error, :contract_lane}

      :error ->
        {:error, :contract_not_registered}
    end
  end

  defp held(%{contract_id: id, contract_version: version, contract_bundle_sha256: bundle}, local) do
    case Map.fetch(local.contracts, {id, version}) do
      {:ok, %{contract_bundle_sha256: ^bundle}} -> :ok
      _ -> {:error, :contract_bundle_not_held}
    end
  end
end
