defmodule ServiceRadar.SweepJobs.LeaseSettingsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.LeaseSettings
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

  defp row(scope, attrs), do: struct!(%SweepLeaseSetting{scope: scope, scope_key: ""}, attrs)

  @day 86_400

  test "with no settings nothing is leased and the horizon is the default" do
    assert %{enabled?: false, horizon_seconds: 7 * @day} == LeaseSettings.combine([])
  end

  test "the agent's value overrides its partition's, which overrides the global one" do
    global = row(:global, leasing_enabled: true, horizon_seconds: 2 * @day)
    partition = row(:partition, leasing_enabled: true, horizon_seconds: 10 * @day)
    agent = row(:agent, leasing_enabled: false, horizon_seconds: 20 * @day)

    assert %{enabled?: true, horizon_seconds: 2 * @day} == LeaseSettings.combine([global])

    assert %{enabled?: true, horizon_seconds: 10 * @day} ==
             LeaseSettings.combine([global, partition])

    assert %{enabled?: false, horizon_seconds: 20 * @day} ==
             LeaseSettings.combine([agent, partition, global])
  end

  test "a field left unset inherits from the wider scope" do
    global = row(:global, leasing_enabled: true, horizon_seconds: 3 * @day)
    agent = row(:agent, horizon_seconds: 14 * @day)

    assert %{enabled?: true, horizon_seconds: 14 * @day} == LeaseSettings.combine([global, agent])
  end

  test "an agent set to off is off even when its partition is on" do
    partition = row(:partition, leasing_enabled: true)
    agent = row(:agent, leasing_enabled: false)

    assert %{enabled?: false} = LeaseSettings.combine([partition, agent])
  end

  test "the administrator maximum caps a horizon, and only the global row sets it" do
    global = row(:global, leasing_enabled: true, max_horizon_seconds: 5 * @day)
    agent = row(:agent, horizon_seconds: 30 * @day)

    assert %{horizon_seconds: 5 * @day} ==
             [global, agent] |> LeaseSettings.combine() |> Map.take([:horizon_seconds])

    # The default horizon is itself capped by a smaller maximum.
    assert %{horizon_seconds: 5 * @day} ==
             [global] |> LeaseSettings.combine() |> Map.take([:horizon_seconds])
  end

  test "a maximum on an agent or partition row is ignored" do
    agent = row(:agent, horizon_seconds: 25 * @day, max_horizon_seconds: 1 * @day)

    assert %{horizon_seconds: 25 * @day} ==
             [agent] |> LeaseSettings.combine() |> Map.take([:horizon_seconds])
  end
end
