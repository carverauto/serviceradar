defmodule ServiceRadar.Edge.PipelineReadinessTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.PipelineReadiness
  alias ServiceRadar.Infrastructure.Agent

  @release %AgentRelease{
    version: "9.9.9",
    manifest: %{
      "artifacts" => [%{"os" => "linux", "arch" => "amd64", "url" => "https://example.com/a"}]
    }
  }

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        partitions: MapSet.new(["default", "site-a"]),
        runtime: %{"agent-1" => runtime()},
        release: @release,
        paused_agent_ids: MapSet.new()
      },
      overrides
    )
  end

  defp runtime(overrides \\ %{}) do
    Map.merge(
      %{
        active: true,
        partition: "default",
        os: "linux",
        arch: "amd64",
        deployment_type: "bare_metal"
      },
      overrides
    )
  end

  defp agent(overrides \\ %{}),
    do: struct!(%Agent{uid: "agent-1", status: :connected, metadata: %{}}, overrides)

  defp reasons(agent, facts),
    do: agent |> PipelineReadiness.conditions(facts) |> Enum.map(& &1.reason)

  test "a connected agent in a known partition that the newest release can upgrade is ready" do
    assert PipelineReadiness.conditions(agent(), facts()) == []
  end

  test "the authenticated partition recorded on the agent decides partition_not_found" do
    agent = agent(%{metadata: %{"partition_id" => "site-missing"}})

    assert [%{reason: :partition_not_found, detail: %{partition: "site-missing"}}] =
             PipelineReadiness.conditions(agent, facts())

    # The live check-in's partition is used only when none is recorded, then the device's.
    assert [%{detail: %{partition: "site-b"}}] =
             PipelineReadiness.conditions(
               agent(),
               facts(%{runtime: %{"agent-1" => runtime(%{partition: "site-b"})}})
             )

    assert [%{detail: %{partition: "site-c"}}] =
             PipelineReadiness.conditions(
               agent(%{device: %{partition: "site-c"}}),
               facts(%{runtime: %{"agent-1" => runtime(%{partition: nil})}})
             )
  end

  test "an agent no tracker saw within its window is disconnected, and its upgrade path is not judged" do
    for runtime <- [%{}, %{"agent-1" => runtime(%{active: false})}] do
      assert reasons(agent(), facts(%{runtime: runtime, release: nil})) == [:agent_disconnected]
    end
  end

  test "the release rollout blocks an agent in a paused rollout, with no release, or with no artifact" do
    assert [%{reason: :agent_upgrade_blocked, detail: %{cause: :rollout_paused}}] =
             PipelineReadiness.conditions(
               agent(),
               facts(%{paused_agent_ids: MapSet.new(["agent-1"])})
             )

    assert [%{detail: %{cause: :no_published_release}}] =
             PipelineReadiness.conditions(agent(), facts(%{release: nil}))

    arm = facts(%{runtime: %{"agent-1" => runtime(%{arch: "arm64"})}})

    assert [%{detail: %{cause: :no_release_artifact, release: "9.9.9", platform: "linux/arm64"}}] =
             PipelineReadiness.conditions(agent(), arm)
  end

  test "an agent that runs from an image is upgraded with its image, not by the rollout" do
    for type <- ~w(kubernetes docker container) do
      image = facts(%{runtime: %{"agent-1" => runtime(%{deployment_type: type})}, release: nil})
      assert PipelineReadiness.conditions(agent(), image) == []
    end
  end

  test "a superseded identity has no condition" do
    assert PipelineReadiness.conditions(agent(%{status: :superseded}), facts(%{runtime: %{}})) ==
             []
  end
end
