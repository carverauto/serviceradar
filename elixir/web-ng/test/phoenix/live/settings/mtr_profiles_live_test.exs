defmodule ServiceRadarWebNGWeb.Settings.MtrProfilesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  defmodule SRQLStub do
    @moduledoc false
    def query(query, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:srql_query, query})
      {:ok, %{"results" => [%{"total" => 120}]}}
    end
  end

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)
    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, SRQLStub)
    :persistent_term.put({SRQLStub, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({SRQLStub, :test_pid})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn, scope: scope, actor: SystemActor.system(:mtr_profiles_live_test)}
  end

  test "shows bulk interval guidance and overlap warning for tight intervals", %{
    conn: conn,
    scope: scope,
    actor: actor
  } do
    {:ok, profile} =
      MtrPolicy.create_policy(
        %{
          name: "Bulk Guidance Profile",
          enabled: true,
          partition_id: "default",
          target_selector: %{
            "srql_query" => "in:devices",
            "limit" => 120,
            "agent_id" => "agent-bulk-1"
          },
          baseline_interval_sec: 60,
          baseline_protocol: "icmp",
          baseline_canary_vantages: 0,
          incident_fanout_max_agents: 3,
          incident_cooldown_sec: 600,
          recovery_capture: true,
          consensus_mode: "majority",
          consensus_threshold: 0.66,
          consensus_min_agents: 2
        },
        scope: scope
      )

    _job = create_completed_bulk_job(actor, "agent-bulk-1", 30)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/mtr/#{profile.id}/edit")

    assert html =~ "Bulk baseline guidance for agent-bulk-1"
    assert html =~ "Measured throughput: 60.0 targets/min"
    assert html =~ "Estimated runtime for current scope: 120s"
    assert html =~ "Recommended minimum interval: 150s"
    assert html =~ "120"
    assert html =~ "managed target(s) are currently eligible per baseline run"

    assert html =~
             "Configured interval is tighter than the measured recommendation and is likely to overlap."

    assert_received {:srql_query, query}
    assert query =~ "is_managed:true"
    assert query =~ "stats:\"count() as total\""
  end

  test "explains managed-only eligibility and selector limit caps", %{conn: conn, scope: scope} do
    {:ok, profile} =
      MtrPolicy.create_policy(
        %{
          name: "Managed Scope Profile",
          enabled: true,
          partition_id: "default",
          target_selector: %{
            "srql_query" => "in:devices tags.role:edge",
            "limit" => 25
          },
          baseline_interval_sec: 300,
          baseline_protocol: "icmp",
          baseline_canary_vantages: 0,
          incident_fanout_max_agents: 3,
          incident_cooldown_sec: 600,
          recovery_capture: true,
          consensus_mode: "majority",
          consensus_threshold: 0.66,
          consensus_min_agents: 2
        },
        scope: scope
      )

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/mtr/#{profile.id}/edit")

    assert html =~ "Baseline MTR automation always targets managed devices only."
    assert html =~ "25"

    assert html =~
             "120 eligible managed device(s) match the SRQL query, and the selector limit caps each run at 25 target(s)."
  end

  defp create_completed_bulk_job(actor, agent_id, total_targets) do
    targets =
      Enum.map(1..total_targets, fn idx ->
        "192.0.2.#{rem(idx, 254) + 1}"
      end)

    inserted_at = DateTime.add(DateTime.utc_now(), -60, :second)
    completed_at = DateTime.add(inserted_at, 30, :second)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 900,
          expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
        },
        actor: actor
      )

    {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

    {:ok, command} =
      AgentCommand.complete(command, [result_payload: %{"total_targets" => total_targets}], actor: actor)

    ServiceRadar.Repo.query!(
      "UPDATE platform.agent_commands SET inserted_at = $2, completed_at = $3 WHERE id = $1",
      [command.id, inserted_at, completed_at]
    )

    %{command | inserted_at: inserted_at, completed_at: completed_at}
  end
end
