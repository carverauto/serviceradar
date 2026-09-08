defmodule ServiceRadar.Scans do
  @moduledoc """
  The Scans domain manages ad-hoc, on-demand network sweeps/scans.

  A `ScanRun` is one user-initiated scan against a supplied target list,
  dispatched to a chosen agent over the on-demand command bus. ICMP/TCP
  results land in the `adhoc_scan_results` hypertable (via JetStream +
  the event-writer pipeline) and are read through `ScanResult`; MTR results
  reuse the existing `mtr_traces` hypertable, correlated by `scan_run_id`.

  `ScanPolicySettings` is a singleton holding the inventory-scoping guardrail.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Scans.ScanRun
    resource ServiceRadar.Scans.ScanResult
    resource ServiceRadar.Scans.ScanPolicySettings
  end
end
