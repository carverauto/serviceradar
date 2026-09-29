defmodule ServiceRadar.SweepJobs.LeaseEligibilityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepPlan
  alias ServiceRadar.SweepJobs.LeaseEligibility
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  defp group(overrides \\ %{}) do
    struct!(
      %SweepGroup{
        id: "0192a4a0-0003-7000-8000-000000000003",
        name: "eligible",
        enabled: true,
        partition: "default",
        agent_ids: [],
        interval: "15m",
        schedule_type: :interval,
        static_targets: ["192.0.2.0/24", "198.51.100.9"],
        target_query: nil,
        sweep_modes: ["icmp", "tcp"],
        ports: [22, 443],
        overrides: %{}
      },
      overrides
    )
  end

  test "a group with static targets, plain checks and an interval is eligible" do
    assert {:ok, inputs} = LeaseEligibility.evaluate(group())

    assert inputs.targets == ["192.0.2.0/24", "198.51.100.9"]
    assert inputs.checks == [{1, 1, 0}, {2, 2, 22}, {2, 2, 443}]
    assert inputs.check_set_sha256 == SweepPlan.check_set_sha256(inputs.checks)
    assert inputs.schedule == {:interval, 900}
  end

  test "the checks are the compiled effective modes and ports, not the group's own fields" do
    # No modes or ports of its own and no profile: the compiler's default is ICMP only.
    assert {:ok, %{checks: [{1, 1, 0}]}} =
             LeaseEligibility.evaluate(group(%{sweep_modes: [], ports: []}))

    # TCP without ports is dropped by the compiler, leaving ICMP.
    assert {:ok, %{checks: [{1, 1, 0}]}} =
             LeaseEligibility.evaluate(group(%{sweep_modes: ["icmp", "tcp"], ports: []}))
  end

  for {label, change, reason} <- [
        {"disabled", %{enabled: false}, :disabled},
        {"an SRQL target query", %{target_query: "in:devices tags:web"}, :has_target_query},
        {"a static target and an SRQL query", %{target_query: "in:devices"}, :has_target_query},
        {"no static targets", %{static_targets: []}, :no_static_targets},
        {"only blank static targets", %{static_targets: ["", "  "]}, :no_static_targets},
        {"MTR mode", %{sweep_modes: ["icmp", "mtr"]}, :mtr_unsupported},
        {"an interval under five minutes", %{interval: "2m"}, :interval_too_short},
        {"an unreadable interval", %{interval: "often"}, :invalid_interval},
        {"a bad cron expression", %{schedule_type: :cron, cron_expression: "x"}, :invalid_cron}
      ] do
    test "#{label} keeps the group on the legacy path" do
      assert {:error, unquote(reason)} =
               LeaseEligibility.evaluate(group(unquote(Macro.escape(change))))
    end
  end

  test "a profile with banner grabbing on keeps the group on the legacy path" do
    profile = struct!(SweepProfile, banner_grab: %{enabled: true, protocols: [:ssh]})

    assert {:error, :banner_grab_enabled} = LeaseEligibility.evaluate(group(), profile)

    assert {:ok, _inputs} =
             LeaseEligibility.evaluate(
               group(),
               struct!(SweepProfile, banner_grab: %{enabled: false})
             )
  end

  test "a target the plan cannot hold keeps the group on the legacy path" do
    assert {:error, {:invalid_target, "10.0.0.10-10.0.0.50"}} =
             LeaseEligibility.evaluate(
               group(%{static_targets: ["192.0.2.1", "10.0.0.10-10.0.0.50"]})
             )

    assert {:error, {:target_too_wide, "2001:db8::/48"}} =
             LeaseEligibility.evaluate(group(%{static_targets: ["2001:db8::/48"]}))
  end

  test "a cron group is eligible and carries its schedule" do
    assert {:ok, %{schedule: {:cron, _}}} =
             LeaseEligibility.evaluate(
               group(%{schedule_type: :cron, cron_expression: "0 */6 * * *"})
             )
  end
end
