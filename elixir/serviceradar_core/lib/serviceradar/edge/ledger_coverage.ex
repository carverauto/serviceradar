defmodule ServiceRadar.Edge.LedgerCoverage do
  @moduledoc """
  How far back the edge-record ledger still proves a record was never applied
  (openspec add-edge-production-time-admission, Decision 5).

  `platform.edge_ledger_coverage.complete_since` is monotonic: every `event_ledger` row with
  `inserted_at` at or after it is still retained. `EdgeLedgerRetentionWorker` advances it in
  the statement that deletes ledger rows, and a trigger refuses to move it backward. No row
  means the ledger has never been pruned (a database built from a schema-only baseline), so
  it covers everything.

  Retention prunes by `inserted_at` while late admission judges `produced_at`, and a producer
  clock may run up to the clock tolerance ahead of core's, so a late record is PRIMARY-eligible
  only when it was produced at least that tolerance after coverage began. An older one is
  delivered as AUDIT (`ledger_pruned`): its earlier application, if any, may be gone.
  """

  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadar.Repo

  @doc "The start of ledger coverage, or `nil` when the ledger has never been pruned."
  @spec complete_since() :: {:ok, DateTime.t() | nil} | {:error, term()}
  def complete_since do
    case Repo.query("SELECT complete_since FROM platform.edge_ledger_coverage WHERE id = 1", []) do
      {:ok, %{rows: [[%DateTime{} = since]]}} -> {:ok, since}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether the ledger still covers a record produced at `produced_at`."
  @spec primary_eligible?(DateTime.t(), DateTime.t() | nil) :: boolean()
  def primary_eligible?(%DateTime{}, nil), do: true

  def primary_eligible?(%DateTime{} = produced_at, %DateTime{} = complete_since) do
    earliest =
      DateTime.add(complete_since, RecordTrust.clock_tolerance_nano(), :nanosecond)

    not DateTime.before?(produced_at, earliest)
  end
end
