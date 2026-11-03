defmodule ServiceRadar.Edge.SweepLeaseCheckSetsCorpusTest do
  @moduledoc """
  M2.0i1: the plan-carried check-set corpus, the encoding half.

  Each `sweep_lease_check_sets_*.bin` fixture is a `SweepLeaseV1` push that this runtime
  encodes from plans and check sets built by `ServiceRadar.Edge.SweepPlan`
  (`SweepPlan.check_set/1`, the set a lease push carries). The committed bytes must equal this encoding, and
  `go/pkg/edge/edgerecord/sweep_lease_check_sets_corpus_test.go` decodes the same files and
  asserts each one's verdict, so a drift in either the Elixir encoding or the Go carrier
  contract fails a test instead of a push the agent refuses.

  Regenerate with `EDGE_GOLDEN_UPDATE=1 mix test <this file>`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepPlan
  alias Serviceradar.Edge.V1.SweepLeaseSlotV1
  alias Serviceradar.Edge.V1.SweepLeaseV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  @group Base.decode16!("0192A4A0000770008000000000000007")
  @lease Base.decode16!("0192A4A0000870008000000000000008")
  @assignment Base.decode16!("0192A4A0000970008000000000000009")
  @scope Base.decode16!("0192A4A0000270008000000000000002")
  @first_slot 1_790_000_000_000_000_000
  @interval 300_000_000_000

  defp checks!(modes, ports) do
    {:ok, checks} = SweepPlan.checks(modes, ports)
    checks
  end

  defp slot(index, check_set_sha256) do
    {:ok, %{header: header, pages: pages}} =
      SweepPlan.build(["192.0.2.0/30", "198.51.100.8/29"],
        plan_id: <<0x0192A4A0::32, index::16, 0x7000::16, 0x8000::16, index::48>>,
        network_scope_id: @scope,
        check_set_sha256: check_set_sha256,
        range_id: range_ids(index)
      )

    start = @first_slot + index * @interval

    %SweepLeaseSlotV1{
      execution_id: <<0x0192A4A1::32, index::16, 0x7000::16, 0x8000::16, index::48>>,
      slot_start_unix_nano: start,
      collection_expires_unix_nano: start + @interval,
      plan_header: header,
      plan_pages: pages
    }
  end

  # Canonical UUIDv4-shaped range ids, distinct per slot and per range.
  defp range_ids(slot_index) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      <<slot_index::32, n::16, 4::4, 0::12, 2::2, 0::62>>
    end
  end

  defp push(slots, check_sets, lease_version \\ 2) do
    %SweepLeaseV1{
      lease_version: lease_version,
      sweep_group_id: @group,
      lease_id: @lease,
      producer_assignment_id: @assignment,
      authority_epoch: 3,
      window_start_unix_nano: @first_slot,
      window_end_unix_nano: @first_slot + 4 * @interval,
      slots: slots,
      check_sets: check_sets
    }
  end

  defp corpus do
    tcp = SweepPlan.check_set(checks!(["icmp", "tcp"], [443, 22]))
    icmp = SweepPlan.check_set(checks!(["icmp"], []))
    unreferenced = SweepPlan.check_set(checks!(["tcp"], [80]))
    [_icmp_check, ssh, https] = tcp.checks
    tampered = %{tcp | checks: [hd(tcp.checks), ssh, %{https | port: 8443}]}
    # TCP SYN on 22 and 443 but TCP connect on 80 only: a valid set the scanner, which runs
    # every TCP mode on every port, cannot express.
    mixed = SweepPlan.check_set(checks!(["tcp"], [22, 443]) ++ checks!(["tcp_connect"], [80]))
    future = %{icmp | digest_version: 2}

    slots = [
      slot(0, tcp.check_set_sha256),
      slot(1, tcp.check_set_sha256),
      slot(2, icmp.check_set_sha256)
    ]

    %{
      "sweep_lease_check_sets_accept.bin" => push(slots, [tcp, icmp]),
      "sweep_lease_check_sets_digest_mismatch.bin" => push(slots, [tampered, icmp]),
      "sweep_lease_check_sets_unresolved.bin" => push(slots, [tcp]),
      "sweep_lease_check_sets_unreferenced.bin" => push(slots, [tcp, icmp, unreferenced]),
      "sweep_lease_check_sets_version_1.bin" => push(slots, [tcp, icmp], 1),
      "sweep_lease_check_sets_not_product.bin" =>
        push([slot(0, mixed.check_set_sha256)], [mixed]),
      "sweep_lease_check_sets_unknown_digest_version.bin" =>
        push([slot(0, future.check_set_sha256)], [future])
    }
  end

  test "the committed lease fixtures are this runtime's encoding of the corpus" do
    for {name, lease} <- corpus() do
      bytes = SweepLeaseV1.encode(lease)
      path = Path.join(@testdata, name)

      if System.get_env("EDGE_GOLDEN_UPDATE") == "1", do: File.write!(path, bytes)

      assert File.read!(path) == bytes,
             "#{name} drifted from this encoding; regenerate with EDGE_GOLDEN_UPDATE=1"
    end
  end
end
