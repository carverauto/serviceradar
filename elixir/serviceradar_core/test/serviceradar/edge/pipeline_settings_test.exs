defmodule ServiceRadar.Edge.PipelineSettingsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PipelineSetting
  alias ServiceRadar.Edge.PipelineSettings

  defp row(scope, attrs), do: struct!(%PipelineSetting{scope: scope, scope_key: ""}, attrs)

  @day 86_400
  @mib 1024 * 1024

  test "with no settings the horizon is seven days and the spool budget is 1 GiB" do
    assert %{horizon_seconds: 7 * @day, spool_max_bytes: 1024 * @mib} ==
             PipelineSettings.combine([])
  end

  test "each field takes the agent's value, else its partition's, else the global one" do
    global = row(:global, horizon_seconds: 2 * @day, spool_max_bytes: 512 * @mib)
    partition = row(:partition, horizon_seconds: 10 * @day, spool_max_bytes: 256 * @mib)
    agent = row(:agent, horizon_seconds: 20 * @day)

    assert %{horizon_seconds: 2 * @day, spool_max_bytes: 512 * @mib} ==
             PipelineSettings.combine([global])

    assert %{horizon_seconds: 10 * @day, spool_max_bytes: 256 * @mib} ==
             PipelineSettings.combine([global, partition])

    # The agent sets only the horizon; its budget comes from the partition.
    assert %{horizon_seconds: 20 * @day, spool_max_bytes: 256 * @mib} ==
             PipelineSettings.combine([agent, partition, global])
  end

  test "the administrator maximum caps a horizon, and only the global row sets it" do
    global = row(:global, max_horizon_seconds: 5 * @day)
    agent = row(:agent, horizon_seconds: 30 * @day)

    assert %{horizon_seconds: 5 * @day} ==
             [global, agent] |> PipelineSettings.combine() |> Map.take([:horizon_seconds])

    # The default horizon is itself capped by a smaller maximum.
    assert %{horizon_seconds: 5 * @day} ==
             [global] |> PipelineSettings.combine() |> Map.take([:horizon_seconds])
  end

  test "a maximum on an agent or partition row is ignored" do
    agent = row(:agent, horizon_seconds: 25 * @day, max_horizon_seconds: 1 * @day)

    assert %{horizon_seconds: 25 * @day} ==
             [agent] |> PipelineSettings.combine() |> Map.take([:horizon_seconds])
  end
end
