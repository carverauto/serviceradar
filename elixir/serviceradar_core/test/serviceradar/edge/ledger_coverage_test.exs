defmodule ServiceRadar.Edge.LedgerCoverageTest do
  @moduledoc """
  The ledger-coverage half of late PRIMARY eligibility (openspec
  add-edge-production-time-admission, Decision 5): a late record may be PRIMARY only when
  `produced_at` is at or after `ledger_complete_since` plus the clock tolerance, because
  retention prunes by `inserted_at` and a producer clock may run up to the tolerance ahead.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.LedgerCoverage

  @since ~U[2026-11-01 00:00:00.000000Z]
  @tolerance 300

  test "a record produced at least the tolerance after coverage began is PRIMARY-eligible" do
    assert LedgerCoverage.primary_eligible?(DateTime.shift(@since, second: @tolerance), @since)
    assert LedgerCoverage.primary_eligible?(DateTime.shift(@since, day: 3), @since)
  end

  test "a record produced earlier may already have left the ledger, so it is not" do
    refute LedgerCoverage.primary_eligible?(
             DateTime.shift(@since, second: @tolerance - 1),
             @since
           )

    refute LedgerCoverage.primary_eligible?(DateTime.shift(@since, day: -1), @since)
  end

  test "a ledger that has never been pruned covers every record" do
    assert LedgerCoverage.primary_eligible?(~U[2020-01-01 00:00:00Z], nil)
  end
end
