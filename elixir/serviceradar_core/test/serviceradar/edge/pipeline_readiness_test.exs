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

  # The spool status the gateway records from a default-on agent's hello, as jsonb reads it.
  @open_spool %{"edge_record_spool" => %{"available" => true, "error" => ""}}

  defp agent(overrides \\ %{}),
    do: struct!(%Agent{uid: "agent-1", status: :connected, metadata: @open_spool}, overrides)

  defp reasons(agent, facts),
    do: agent |> PipelineReadiness.conditions(facts) |> Enum.map(& &1.reason)

  test "a connected agent in a known partition that the newest release can upgrade is ready" do
    assert PipelineReadiness.conditions(agent(), facts()) == []
  end

  test "the authenticated partition recorded on the agent decides partition_not_found" do
    agent = agent(%{metadata: Map.put(@open_spool, "partition_id", "site-missing")})

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

  test "an agent whose spool did not open is spool_unavailable, with the error it reported" do
    spool = %{"edge_record_spool" => %{"available" => false, "error" => "spool: mkdir: denied"}}

    assert [%{reason: :spool_unavailable, detail: %{error: "spool: mkdir: denied"}}] =
             PipelineReadiness.conditions(agent(%{metadata: spool}), facts())
  end

  test "a connected agent that reports no spool status runs a build from before the cutover" do
    old = agent(%{metadata: %{}, version: "1.4.0"})

    assert [%{reason: :agent_upgrade_pending, detail: %{version: "1.4.0"}}] =
             PipelineReadiness.conditions(old, facts())

    # An image-delivered agent still has to be upgraded, by its image.
    image = facts(%{runtime: %{"agent-1" => runtime(%{deployment_type: "kubernetes"})}})
    assert reasons(old, image) == [:agent_upgrade_pending]

    # A disconnected agent's last check-in says nothing current about its build.
    assert reasons(old, facts(%{runtime: %{}})) == [:agent_disconnected]
  end

  test "an agent whose durable status-path data the gateway refused is upgrade pending, with the counts" do
    refused_at = ~U[2026-11-04 12:00:00Z]

    refusing =
      facts(%{
        runtime: %{
          "agent-1" =>
            runtime(%{
              refused_statuses: %{"sysmon-metrics" => 3, "results" => 1},
              last_refused_at: refused_at
            })
        }
      })

    # Even a build that reports its spool still sends on the retired path, so it is not ready.
    assert [
             %{
               reason: :agent_upgrade_pending,
               detail: %{
                 version: "1.4.1",
                 refused_statuses: %{"sysmon-metrics" => 3, "results" => 1},
                 last_refused_at: ^refused_at
               }
             }
           ] = PipelineReadiness.conditions(agent(%{version: "1.4.1"}), refusing)

    # A build without spool status gets one condition that carries both facts.
    assert [%{reason: :agent_upgrade_pending, detail: %{refused_statuses: %{"results" => 1}}}] =
             PipelineReadiness.conditions(agent(%{metadata: %{}, version: "1.4.0"}), refusing)
  end

  test "an oversized summary is its own condition naming the service and size, not an upgrade" do
    refused_at = ~U[2026-11-04 12:00:00Z]
    snmp = %{bytes: 4_812, limit: 4_096}

    oversized_only =
      runtime(%{
        refused_statuses: %{"oversized_summary" => 35},
        oversized_summaries: %{"snmp" => snmp},
        last_refused_at: refused_at
      })

    # A current build that reports its spool and sends only an oversized summary.
    assert [
             %{
               reason: :oversized_summary,
               detail: %{count: 35, summaries: %{"snmp" => ^snmp}, last_refused_at: ^refused_at}
             }
           ] =
             PipelineReadiness.conditions(
               agent(%{version: "1.4.102"}),
               facts(%{runtime: %{"agent-1" => oversized_only}})
             )

    # Retired sources alongside it still make the agent upgrade pending, without the
    # oversized count in that condition.
    mixed =
      runtime(%{
        refused_statuses: %{"oversized_summary" => 2, "results" => 1},
        oversized_summaries: %{"snmp" => snmp},
        last_refused_at: refused_at
      })

    assert [
             %{reason: :agent_upgrade_pending, detail: %{refused_statuses: refused}},
             %{reason: :oversized_summary, detail: %{count: 2}}
           ] =
             PipelineReadiness.conditions(
               agent(%{version: "1.4.1"}),
               facts(%{runtime: %{"agent-1" => mixed}})
             )

    assert refused == %{"results" => 1}
  end
end
