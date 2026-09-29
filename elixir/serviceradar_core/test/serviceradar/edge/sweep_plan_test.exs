defmodule ServiceRadar.Edge.SweepPlanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SweepPlan

  @plan_id Base.decode16!("0192A4A0000170008000000000000001")
  @scope Base.decode16!("0192A4A0000270008000000000000002")
  @check_set :crypto.hash(:sha256, "check-set")

  # A fresh canonical range id per call: version nibble 4, variant bits 10.
  defp range_id_fun do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      <<n::48, 4::4, 0::12, 2::2, 0::62>>
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        plan_id: @plan_id,
        network_scope_id: @scope,
        check_set_sha256: @check_set,
        range_id: range_id_fun()
      ],
      extra
    )
  end

  describe "canonical_target/1" do
    for {raw, cidr, count} <- [
          {"192.0.2.5", "192.0.2.5/32", 1},
          {"192.0.2.5/24", "192.0.2.0/24", 256},
          {"  198.51.100.0/25 ", "198.51.100.0/25", 128},
          {"0.0.0.0/0", "0.0.0.0/0", 4_294_967_296},
          {"2001:DB8:0:0:0:0:0:1", "2001:db8::1/128", 1},
          {"2001:db8::ff/120", "2001:db8::/120", 256},
          {"2001:db8::ffff/120", "2001:db8::ff00/120", 256},
          {"2001:db8::/65", "2001:db8::/65", 9_223_372_036_854_775_808}
        ] do
      test "#{inspect(raw)} is #{cidr}" do
        assert {:ok, %{cidr: unquote(cidr), count: unquote(count)}} =
                 SweepPlan.canonical_target(unquote(raw))
      end
    end

    for bad <- [
          "",
          "not-an-ip",
          "10.0.0.1/33",
          "10.0.0.1/-1",
          "10.0.0.1/x",
          "fe80::1%eth0",
          "10.0.0/24"
        ] do
      test "#{inspect(bad)} is refused" do
        assert {:error, {:invalid_target, _}} = SweepPlan.canonical_target(unquote(bad))
      end
    end

    test "an IPv6 prefix shorter than /65 holds more addresses than a count can carry" do
      assert {:error, {:target_too_wide, "2001:db8::/64"}} =
               SweepPlan.canonical_target("2001:db8::/64")

      assert {:error, {:target_too_wide, "::/0"}} = SweepPlan.canonical_target("::/0")
    end
  end

  describe "checks/2" do
    test "ICMP once and each TCP mode on every port, in a stable order" do
      assert {:ok, [{1, 1, 0}, {2, 2, 22}, {2, 2, 443}, {3, 2, 22}, {3, 2, 443}]} =
               SweepPlan.checks(["tcp_connect", "TCP", "icmp", "arp", ""], [443, 22, 443])
    end

    test "ICMP alone needs no ports" do
      assert {:ok, [{1, 1, 0}]} = SweepPlan.checks(["icmp"], [])
    end

    test "refuses what a plan built here cannot carry" do
      assert {:error, :mtr_unsupported} = SweepPlan.checks(["icmp", "mtr"], [])
      assert {:error, :no_ports} = SweepPlan.checks(["tcp"], [])
      assert {:error, :no_checks} = SweepPlan.checks(["arp"], [80])
      assert {:error, {:unsupported_mode, "udp"}} = SweepPlan.checks(["udp"], [])
      assert {:error, {:invalid_port, 70_000}} = SweepPlan.checks(["tcp"], [70_000])
    end

    test "the check set identity ignores the order the checks are listed in" do
      {:ok, a} = SweepPlan.checks(["icmp", "tcp"], [22, 80])
      {:ok, b} = SweepPlan.checks(["tcp", "icmp"], [80, 22])

      assert SweepPlan.check_set_sha256(a) == SweepPlan.check_set_sha256(Enum.reverse(b))
      refute SweepPlan.check_set_sha256(a) == SweepPlan.check_set_sha256([{1, 1, 0}])
    end
  end

  describe "build/2" do
    test "one range per configured target, ordered, and a plan the validator accepts" do
      targets = ["203.0.113.0/25", "2001:db8::1", "192.0.2.5", "198.51.100.77/24", "192.0.2.5/32"]

      assert {:ok, %{header: header, pages: [page]}} = SweepPlan.build(targets, opts())

      assert Enum.map(page.ranges, & &1.cidr) == [
               "192.0.2.5/32",
               "198.51.100.0/24",
               "203.0.113.0/25",
               "2001:db8::1/128"
             ]

      assert header.total_target_count == 1 + 256 + 128 + 1
      assert header.availability_policy_id == SweepPlan.availability_policy_id()
      assert header.execution_plan_sha256 == HashGrammar.plan_header_digest(header)
      assert {:ok, _windows} = PlanValidate.validate(header, [page])
    end

    test "more than 256 targets continue on a chained page" do
      targets = for i <- 1..257, do: "10.#{div(i, 256)}.#{rem(i, 256)}.1/32"

      assert {:ok, %{header: header, pages: [first, second]}} = SweepPlan.build(targets, opts())

      assert length(first.ranges) == 256
      assert length(second.ranges) == 1
      assert first.prev_page_sha256 == ""
      assert second.prev_page_sha256 == first.page_sha256
      assert header.page_count == 2
      assert {:ok, _windows} = PlanValidate.validate(header, [first, second])
    end

    test "the same targets and ids give the same plan whatever order they arrive in" do
      {:ok, a} = SweepPlan.build(["10.0.0.1", "10.0.1.0/24"], opts())
      {:ok, b} = SweepPlan.build(["10.0.1.0/24", "10.0.0.1"], opts())

      assert a.header.execution_plan_sha256 == b.header.execution_plan_sha256
    end

    test "refuses a plan it cannot represent, and returns no plan" do
      assert {:error, :no_targets} = SweepPlan.build([], opts())
      assert {:error, {:invalid_target, "nope"}} = SweepPlan.build(["10.0.0.1", "nope"], opts())
      assert {:error, {:target_too_wide, _}} = SweepPlan.build(["2001:db8::/48"], opts())
    end

    test "refuses a missing or malformed identity" do
      assert {:error, {:invalid_option, :plan_id}} =
               SweepPlan.build(["10.0.0.1"], opts(plan_id: "short"))

      assert {:error, {:invalid_option, :check_set_sha256}} =
               SweepPlan.build(["10.0.0.1"], opts(check_set_sha256: <<1, 2>>))

      # A plan id must be a UUIDv7: the header refuses anything else.
      v4 = <<1::48, 4::4, 0::12, 2::2, 0::62>>

      assert {:error, {:invalid_plan, :header_identity}} =
               SweepPlan.build(["10.0.0.1"], opts(plan_id: v4))
    end
  end
end
