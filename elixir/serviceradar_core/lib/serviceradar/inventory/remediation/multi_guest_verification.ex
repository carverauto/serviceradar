defmodule ServiceRadar.Inventory.Remediation.MultiGuestVerification do
  @moduledoc """
  Step `multi-guest-verify`: the read-only check of `multi-guest-split` (OpenSpec
  `prevent-multi-guest-device-records`), refused under execute. It lists every live record holding
  more than one live Proxmox v3 guest reference, so it runs before the split, after it, and after
  any number of later syncs.

  `G1` passes when there is none. A failing check counts in `verification_failures`, which fails
  the run. Run it after the next sync of every Proxmox integration: a record a sync built again
  after the split is a resolution defect, not a leftover.
  """

  alias ServiceRadar.Inventory.Remediation.MultiGuestSplit

  @sample 50
  @limit 5_000

  @doc false
  def run(_mode, opts, _manifest, _actor) do
    limit = Keyword.get(opts, :multi_guest_split_candidate_limit, @limit)
    uids = MultiGuestSplit.candidate_uids(limit + 1)
    truncated? = length(uids) > limit
    findings = Enum.take(uids, limit)

    status =
      cond do
        truncated? -> "fail"
        findings == [] -> "pass"
        true -> "fail"
      end

    check = %{
      check: "G1",
      status: status,
      count: length(findings),
      sample: Enum.take(findings, @sample)
    }

    check = if truncated?, do: Map.put(check, :reason, "candidate_limit_reached"), else: check

    %{
      multi_guest_records: length(findings),
      candidate_limit_reached: truncated?,
      checks: [check],
      verification_failures: if(status == "fail", do: 1, else: 0)
    }
  end
end
