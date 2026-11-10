defmodule ServiceRadar.Edge.Projectors.RecoveryControl do
  @moduledoc """
  Projects authenticated recovery controls through the EdgeRecord ledger transaction.
  Exact incomplete receipts may ACK; mapping work deferred after commit must redeliver.
  A ledger replay revisits durable operation state, while a late-fenced delivery remains
  ledger-only. The operation owner validates declared cost against the entire manifest.
  """
  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.RecoveryOperations
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @contract_id "serviceradar.edge.recovery_control"

  @impl true
  def decode(
        %EdgeRecordV1{
          output_contract: %{contract_id: @contract_id, contract_version: 1} = contract
        } = record
      ),
      do: RecoveryValidate.recovery_control_body(record, contract)

  def decode(_record), do: {:error, :contract_dispatch}

  @impl true
  def project(_repo, _record, _body, %{late_fenced?: true}), do: :ok

  def project(_repo, record, %{bytes: bytes}, %{late_fenced?: false}) do
    cost = %{rows: record.projected_row_count, bytes: record.projected_write_bytes}

    case RecoveryOperations.consume_control(
           record.network_scope_id,
           record.producer_context.origin_principal_id,
           bytes,
           cost
         ) do
      {:ok, state} when state in [:received, :applied] -> :ok
      {:ok, state} when state in [:pending, :blocked] -> {:defer, state}
      {:error, _} = error -> error
    end
  end
end
