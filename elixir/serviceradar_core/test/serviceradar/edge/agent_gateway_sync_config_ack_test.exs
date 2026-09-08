defmodule ServiceRadar.Edge.AgentGatewaySyncConfigAckTest do
  @moduledoc """
  DB-backed tests for config-ack persistence (gateway → core RPC surface) and the
  config-health transitions driven by StateMonitor evaluation:

  - `record_config_ack/2` persists the acked version + per-section statuses;
    legacy acks (no section statuses) update the version without touching the
    previously recorded section detail.
  - `record_config_push/2` records the first-push timestamp of a version and does
    not refresh it on a re-push of the same version.
  - `evaluate_agent_config_health/3` transitions config_health on wedge and clear.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.StateMonitor

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    actor = SystemActor.system(:test)
    uid = "agent-config-ack-#{unique_id}"

    {:ok, agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{uid: uid, name: "Config Ack Agent", host: "192.168.1.50", port: 50_051},
        actor: actor
      )
      |> Ash.create()

    {:ok, actor: actor, agent: agent, uid: uid}
  end

  defp reload!(uid, actor) do
    {:ok, agent} = Agent.get_by_uid(uid, actor: actor)
    agent
  end

  describe "record_config_ack/2" do
    test "persists version, timestamp, and per-section statuses", %{uid: uid, actor: actor} do
      sections = [
        %{"section" => "bumblebee", "disposition" => "success", "error" => "", "since" => nil},
        %{
          "section" => "visibility",
          "disposition" => "permanent_failure",
          "error" => "merge netprobe add-on config: cannot unmarshal string",
          "since" => "2026-07-01T00:44:00Z"
        }
      ]

      acked_at = ~U[2026-07-04 10:00:00Z]

      assert :ok =
               AgentGatewaySync.record_config_ack(uid, %{
                 config_version: "v2",
                 acked_at: acked_at,
                 section_statuses: sections
               })

      agent = reload!(uid, actor)
      assert agent.acked_config_version == "v2"
      assert agent.config_acked_at == acked_at

      assert [_, %{"section" => "visibility", "disposition" => "permanent_failure"} = failing] =
               agent.config_section_statuses

      assert failing["error"] =~ "cannot unmarshal string"
    end

    test "legacy whole-version ack updates the version but keeps recorded sections", %{
      uid: uid,
      actor: actor
    } do
      :ok =
        AgentGatewaySync.record_config_ack(uid, %{
          config_version: "v1",
          acked_at: ~U[2026-07-04 09:00:00Z],
          section_statuses: [
            %{"section" => "addons", "disposition" => "permanent_failure", "error" => "boom"}
          ]
        })

      assert :ok =
               AgentGatewaySync.record_config_ack(uid, %{
                 config_version: "v2",
                 acked_at: ~U[2026-07-04 09:05:00Z],
                 section_statuses: nil
               })

      agent = reload!(uid, actor)
      assert agent.acked_config_version == "v2"
      assert [%{"section" => "addons"}] = agent.config_section_statuses
    end

    test "returns an error for unknown agents" do
      assert {:error, _reason} =
               AgentGatewaySync.record_config_ack("agent-does-not-exist", %{
                 config_version: "v1",
                 acked_at: DateTime.utc_now(),
                 section_statuses: nil
               })
    end
  end

  describe "record_config_push/2" do
    test "records the first push and does not refresh on a same-version re-push", %{
      uid: uid,
      actor: actor
    } do
      first_push = ~U[2026-07-04 08:00:00Z]

      assert :ok =
               AgentGatewaySync.record_config_push(uid, %{
                 config_version: "v2",
                 pushed_at: first_push
               })

      assert :ok =
               AgentGatewaySync.record_config_push(uid, %{
                 config_version: "v2",
                 pushed_at: ~U[2026-07-04 11:00:00Z]
               })

      agent = reload!(uid, actor)
      assert agent.pushed_config_version == "v2"
      assert agent.config_pushed_at == first_push

      # A new version resets the anchor.
      assert :ok =
               AgentGatewaySync.record_config_push(uid, %{
                 config_version: "v3",
                 pushed_at: ~U[2026-07-04 11:30:00Z]
               })

      agent = reload!(uid, actor)
      assert agent.pushed_config_version == "v3"
      assert agent.config_pushed_at == ~U[2026-07-04 11:30:00Z]
    end
  end

  describe "evaluate_agent_config_health/3" do
    test "no-ack window wedges, ack clears", %{uid: uid, actor: actor} do
      :ok =
        AgentGatewaySync.record_config_push(uid, %{
          config_version: "v2",
          pushed_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      threshold = DateTime.add(DateTime.utc_now(), -1800, :second)

      :ok = StateMonitor.evaluate_agent_config_health(reload!(uid, actor), threshold, actor)
      assert reload!(uid, actor).config_health == :unhealthy

      # The agent acks the pushed version -> clears on the next evaluation.
      :ok =
        AgentGatewaySync.record_config_ack(uid, %{
          config_version: "v2",
          acked_at: DateTime.utc_now(),
          section_statuses: nil
        })

      :ok = StateMonitor.evaluate_agent_config_health(reload!(uid, actor), threshold, actor)
      assert reload!(uid, actor).config_health == :healthy
    end

    test "permanent section failure wedges despite fresh acks", %{uid: uid, actor: actor} do
      :ok =
        AgentGatewaySync.record_config_ack(uid, %{
          config_version: "v2",
          acked_at: DateTime.utc_now(),
          section_statuses: [
            %{
              "section" => "visibility",
              "disposition" => "permanent_failure",
              "error" => "merge netprobe add-on config: parse error",
              "since" => "2026-07-01T00:44:00Z"
            }
          ]
        })

      threshold = DateTime.add(DateTime.utc_now(), -1800, :second)

      :ok = StateMonitor.evaluate_agent_config_health(reload!(uid, actor), threshold, actor)
      assert reload!(uid, actor).config_health == :unhealthy
    end
  end
end
