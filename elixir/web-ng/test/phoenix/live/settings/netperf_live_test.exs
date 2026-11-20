defmodule ServiceRadarWebNGWeb.Settings.NetperfLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Ash.Expr
  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandsPubSub
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfPolicyResponder
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  defmodule CommandBusStub do
    @moduledoc false
    def dispatch_netperf_run(sender_agent_id, params, opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:netperf_run_dispatched, sender_agent_id, params, opts})

      case :persistent_term.get({__MODULE__, :result}, {:ok, Ecto.UUID.generate()}) do
        {:ok, cmd_id} -> {:ok, cmd_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp unique_uid(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp register_agent!(uid, attrs \\ %{}) do
    base = %{uid: uid, ip: "198.51.100.10", host: "#{uid}.example.test"}

    Agent
    |> Ash.Changeset.for_create(:register, Map.merge(base, attrs), actor: system_actor())
    |> Ash.create!()
  end

  describe "authentication and RBAC gating" do
    test "unauthenticated request redirects to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/settings/networks/netperf")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "viewer without settings.networks.manage is redirected to /settings/profile", %{
      conn: conn
    } do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      conn = log_in_user(conn, viewer)

      for path <- [
            ~p"/settings/networks/netperf",
            ~p"/settings/networks/netperf/policies/new",
            ~p"/settings/networks/netperf/responders/new",
            ~p"/settings/networks/netperf/profiles/new"
          ] do
        assert {:error, {:redirect, %{to: "/settings/profile"}}} = live(conn, path)
      end
    end

    test "connected admin downgraded to viewer is blocked on subsequent LiveView events without mutating or dispatching",
         %{conn: conn} do
      _other_admin = AccountsFixtures.user_fixture(%{role: :admin})
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf")

      {:ok, profile_lv, _html} =
        live(log_in_user(build_conn(), admin), ~p"/settings/networks/netperf/profiles/new")

      {:ok, _downgraded} =
        User.update_role(admin, %{role: :viewer}, actor: system_actor())

      assert {:error, {:redirect, %{to: "/settings/profile"}}} =
               render_click(lv, "open_run_modal", %{})

      flash = assert_redirect(lv, "/settings/profile")
      assert flash["error"] =~ "Not authorized"

      bad_profile_name = unique_uid("Unauthorized Profile")

      assert {:error, {:redirect, %{to: "/settings/profile"}}} =
               profile_lv
               |> form("#netperf-profile-form", profile: %{"name" => bad_profile_name})
               |> render_submit()

      profile_flash = assert_redirect(profile_lv, "/settings/profile")
      assert profile_flash["error"] =~ "Not authorized"

      assert {:error, {:redirect, %{to: "/settings/profile"}}} =
               live(log_in_user(build_conn(), admin), ~p"/settings/networks/netperf/profiles/new")

      assert {:error, _} = NetperfProfile.get_by_name(bad_profile_name, actor: system_actor())
    end
  end

  describe "tabs, CRUD, authority_epoch, and Run Test Now" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      conn = log_in_user(conn, admin)
      %{conn: conn, admin: admin}
    end

    test "switches between Policies, Hub Responders, and Profiles tabs", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/settings/networks/netperf")
      assert html =~ "Network Performance"
      assert has_element?(lv, "#netperf-policies-table")

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf?tab=responders")
      assert has_element?(lv, "#netperf-responders-table")

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf?tab=profiles")
      assert has_element?(lv, "#netperf-profiles-table")
    end

    test "creates, validates, edits, and deletes NetperfProfile", %{conn: conn} do
      name = unique_uid("WAN Baseline")

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf/profiles/new")

      # Validation error: omit_sec >= duration_sec must stay on form without crashing
      html =
        lv
        |> form("#netperf-profile-form",
          profile: %{
            "name" => name,
            "protocol" => "udp",
            "direction" => "bidirectional",
            "bandwidth_bps" => "25000000",
            "duration_sec" => "3",
            "omit_sec" => "3",
            "parallel" => "2",
            "packet_length" => "1200",
            "interval_seconds" => "300"
          }
        )
        |> render_submit()

      assert html =~ "Failed to save profile"
      assert {:error, _} = NetperfProfile.get_by_name(name, actor: system_actor())

      # Malformed integer input must fail validation rather than coercing to a default
      bad_int_html =
        lv
        |> form("#netperf-profile-form",
          profile: %{
            "name" => name,
            "protocol" => "udp",
            "direction" => "bidirectional",
            "bandwidth_bps" => "25000000",
            "duration_sec" => "abc",
            "omit_sec" => "2",
            "parallel" => "2",
            "packet_length" => "1200",
            "interval_seconds" => "300"
          }
        )
        |> render_submit()

      assert bad_int_html =~ "Failed to save profile"
      assert {:error, _} = NetperfProfile.get_by_name(name, actor: system_actor())

      # Valid submit
      lv
      |> form("#netperf-profile-form",
        profile: %{
          "name" => name,
          "protocol" => "udp",
          "direction" => "bidirectional",
          "bandwidth_bps" => "25000000",
          "duration_sec" => "10",
          "omit_sec" => "2",
          "parallel" => "2",
          "packet_length" => "1200",
          "interval_seconds" => "300"
        }
      )
      |> render_submit()

      assert {:ok, profile} = NetperfProfile.get_by_name(name, actor: system_actor())
      assert profile.protocol == :udp
      assert profile.direction == :bidirectional
      assert profile.bandwidth_bps == 25_000_000

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf?tab=profiles")

      lv
      |> element("button[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert {:error, _} = NetperfProfile.get_by_id(profile.id, actor: system_actor())
    end

    test "creates Hub Responder, bumps authority_epoch, and increments epoch on disable", %{
      conn: conn
    } do
      hub_uid = unique_uid("agent-hub")
      register_agent!(hub_uid, %{ip: "198.51.100.42"})

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf/responders/new")

      lv |> element("#netperf-responder-agent-picker-trigger") |> render_click()
      assert has_element?(lv, "#agent-picker-modal")

      lv
      |> element("#agent-picker-modal button[phx-click='agent_picker_select'][phx-value-uid='#{hub_uid}']")
      |> render_click()

      lv
      |> form("#netperf-responder-form",
        responder: %{
          "name" => "Primary Hub",
          "advertise_address" => "198.51.100.42",
          "listen_port" => "5199",
          "udp_enabled" => "true",
          "enabled" => "true",
          "max_concurrent_sessions" => "8",
          "max_total_bandwidth_bps" => "2000000000"
        }
      )
      |> render_submit()

      assert {:ok, responder} = NetperfResponder.get_by_agent_uid(hub_uid, actor: system_actor())
      assert responder.authority_epoch == 1
      assert responder.enabled == true

      {:ok, lv, html} = live(conn, ~p"/settings/networks/netperf?tab=responders")
      assert html =~ "Primary Hub"
      assert html =~ "epoch 1"

      # Bump authority epoch via UI button
      lv
      |> element("button[phx-click='bump_authority_epoch'][phx-value-id='#{responder.id}']")
      |> render_click()

      {:ok, bumped} = NetperfResponder.get_by_id(responder.id, actor: system_actor())
      assert bumped.authority_epoch == 2

      # Disable responder -> increments authority_epoch to 3
      lv
      |> element("button[phx-click='toggle_responder'][phx-value-id='#{responder.id}']")
      |> render_click()

      {:ok, disabled} = NetperfResponder.get_by_id(responder.id, actor: system_actor())
      assert disabled.enabled == false
      assert disabled.authority_epoch == 3
    end

    test "creates hub_and_spoke and hub_mesh policies with responder links and validates SRQL selector",
         %{conn: conn} do
      hub1_uid = unique_uid("agent-hub-1")
      hub2_uid = unique_uid("agent-hub-2")
      register_agent!(hub1_uid)
      register_agent!(hub2_uid)

      {:ok, profile} =
        NetperfProfile.create_profile(%{name: unique_uid("Policy Profile")},
          actor: system_actor()
        )

      {:ok, resp1} =
        NetperfResponder.create_responder(%{agent_uid: hub1_uid, name: "Hub One"},
          actor: system_actor()
        )

      {:ok, resp2} =
        NetperfResponder.create_responder(%{agent_uid: hub2_uid, name: "Hub Two"},
          actor: system_actor()
        )

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf/policies/new")

      # Invalid spoke_selector SRQL (targets alerts instead of agents/devices)
      bad_name = unique_uid("Bad Selector Policy")

      html =
        lv
        |> form("#netperf-policy-form",
          policy: %{
            "name" => bad_name,
            "mode" => "hub_and_spoke",
            "profile_id" => profile.id,
            "spoke_srql_query" => "in:alerts"
          }
        )
        |> render_submit()

      assert html =~ "Failed to save policy"

      # Valid hub_and_spoke policy with attached responder + spoke_selector
      policy_name = unique_uid("Branch to Hub")

      lv
      |> form("#netperf-policy-form",
        policy: %{
          "name" => policy_name,
          "mode" => "hub_and_spoke",
          "enabled" => "true",
          "profile_id" => profile.id,
          "responder_ids" => [resp1.id],
          "spoke_partition_id" => "default",
          "spoke_tags_text" => "site=branch",
          "spoke_srql_query" => "in:agents status:connected"
        }
      )
      |> render_submit()

      [policy] =
        NetperfPolicy
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(expr(name == ^policy_name))
        |> Ash.read!(actor: system_actor())

      assert policy.mode == :hub_and_spoke
      assert policy.spoke_selector["partition_id"] == "default"
      assert policy.spoke_selector["tags"] == %{"site" => "branch"}

      {:ok, links} = NetperfPolicyResponder.list_for_policy(policy.id, actor: system_actor())
      assert Enum.map(links, & &1.responder_id) == [resp1.id]

      # Hub Mesh policy linking both responders
      {:ok, mesh_lv, _html} = live(conn, ~p"/settings/networks/netperf/policies/new")
      mesh_name = unique_uid("Core Hub Mesh")

      mesh_lv
      |> form("#netperf-policy-form",
        policy: %{
          "name" => mesh_name,
          "mode" => "hub_mesh",
          "enabled" => "true",
          "profile_id" => profile.id,
          "responder_ids" => [resp1.id, resp2.id]
        }
      )
      |> render_submit()

      [mesh_policy] =
        NetperfPolicy
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(expr(name == ^mesh_name))
        |> Ash.read!(actor: system_actor())

      assert mesh_policy.mode == :hub_mesh
      assert mesh_policy.spoke_selector == %{}

      {:ok, mesh_links} =
        NetperfPolicyResponder.list_for_policy(mesh_policy.id, actor: system_actor())

      assert Enum.sort(Enum.map(mesh_links, & &1.responder_id)) == Enum.sort([resp1.id, resp2.id])

      # Profile in use by policy cannot be deleted (on_delete: :restrict)
      {:ok, prof_lv, _html} = live(conn, ~p"/settings/networks/netperf?tab=profiles")

      prof_html =
        prof_lv
        |> element("button[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
        |> render_click()

      assert prof_html =~ "Failed to delete profile"
    end

    test "disabled New Policy button renders as button, mode switch preserves spoke selector, and mismatched save_* does not crash",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf")
      assert has_element?(lv, "button#netperf-new-policy-btn[disabled]")
      refute has_element?(lv, "a#netperf-new-policy-btn")

      # Mismatched save_* when @show_form is nil returns flash error without crashing
      for {event, key} <- [
            {"save_policy", "policy"},
            {"save_responder", "responder"},
            {"save_profile", "profile"}
          ] do
        html = render_hook(lv, event, %{key => %{"name" => "orphan"}})
        assert html =~ "Form is no longer active"
      end

      {:ok, _profile} =
        NetperfProfile.create_profile(%{name: unique_uid("Mode Switch Profile")},
          actor: system_actor()
        )

      spoke_uid = unique_uid("agent-spoke")
      register_agent!(spoke_uid)

      {:ok, policy_lv, _html} = live(conn, ~p"/settings/networks/netperf/policies/new")

      policy_lv
      |> form("#netperf-policy-form",
        policy: %{
          "mode" => "hub_and_spoke",
          "spoke_partition_id" => "branch-west",
          "spoke_tags_text" => "site=branch-01",
          "spoke_srql_query" => "in:agents status:connected"
        }
      )
      |> render_change()

      policy_lv |> element("#netperf-policy-spoke-agents-picker-trigger") |> render_click()

      policy_lv
      |> element("#agent-picker-modal button[phx-click='agent_picker_select'][phx-value-uid='#{spoke_uid}']")
      |> render_click()

      policy_lv |> element("#agent-picker-modal button[phx-click='close_agent_picker']", "Done") |> render_click()

      policy_lv
      |> form("#netperf-policy-form", policy: %{"mode" => "hub_mesh"})
      |> render_change()

      assert has_element?(policy_lv, "#netperf-spoke-selector-fields.hidden")

      policy_lv
      |> form("#netperf-policy-form", policy: %{"mode" => "hub_and_spoke"})
      |> render_change()

      refute has_element?(policy_lv, "#netperf-spoke-selector-fields.hidden")

      assert has_element?(
               policy_lv,
               "#netperf-policy-form input[name='policy[spoke_partition_id]'][value='branch-west']"
             )

      assert has_element?(
               policy_lv,
               "#netperf-policy-form input[name='policy[spoke_tags_text]'][value='site=branch-01']"
             )

      assert has_element?(
               policy_lv,
               "#netperf-policy-form input[name='policy[spoke_srql_query]'][value='in:agents status:connected']"
             )

      assert has_element?(
               policy_lv,
               "#netperf-policy-form input[name='policy[spoke_agent_uids_text]'][value='#{spoke_uid}']"
             )
    end

    test "Run Test Now modal render_change preserves manual overrides and rejects invalid numeric inputs",
         %{conn: conn, admin: admin} do
      spoke_uid = unique_uid("agent-spoke")
      hub1_uid = unique_uid("agent-hub-1")
      hub2_uid = unique_uid("agent-hub-2")
      register_agent!(spoke_uid, %{ip: "198.51.100.20"})
      register_agent!(hub1_uid, %{ip: "198.51.100.21"})
      register_agent!(hub2_uid, %{ip: "198.51.100.22"})

      NetperfResponder.create_responder!(
        %{agent_uid: hub1_uid, name: "Hub One", advertise_address: "198.51.100.21", listen_port: 5199},
        actor: system_actor()
      )

      NetperfResponder.create_responder!(
        %{agent_uid: hub2_uid, name: "Hub Two", advertise_address: "198.51.100.22", listen_port: 5201},
        actor: system_actor()
      )

      {:ok, profile} =
        NetperfProfile.create_profile(
          %{
            name: unique_uid("UDP Override Profile"),
            protocol: :udp,
            direction: :download,
            bandwidth_bps: 25_000_000,
            duration_sec: 12,
            omit_sec: 2,
            parallel: 3,
            packet_length: 1400
          },
          actor: system_actor()
        )

      prev_bus = Application.get_env(:serviceradar_web_ng, :netperf_command_bus)
      cmd_id = Ecto.UUID.generate()
      :persistent_term.put({CommandBusStub, :test_pid}, self())
      :persistent_term.put({CommandBusStub, :result}, {:ok, cmd_id})
      Application.put_env(:serviceradar_web_ng, :netperf_command_bus, CommandBusStub)

      on_exit(fn ->
        :persistent_term.erase({CommandBusStub, :test_pid})
        :persistent_term.erase({CommandBusStub, :result})

        if is_nil(prev_bus) do
          Application.delete_env(:serviceradar_web_ng, :netperf_command_bus)
        else
          Application.put_env(:serviceradar_web_ng, :netperf_command_bus, prev_bus)
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf")
      lv |> element("#netperf-run-test-btn") |> render_click()

      # Switching responder updates target_address and target_port
      lv
      |> form("#netperf-run-form", run: %{"responder_agent_id" => hub2_uid})
      |> render_change()

      assert has_element?(lv, "#netperf-run-form input[name='run[target_address]'][value='198.51.100.22']")
      assert has_element?(lv, "#netperf-run-form input[name='run[target_port]'][value='5201']")

      # Selecting profile populates profile parameters
      lv
      |> form("#netperf-run-form", run: %{"profile_id" => profile.id})
      |> render_change()

      assert has_element?(lv, "#netperf-run-form input[name='run[bandwidth_bps]'][value='25000000']")
      assert has_element?(lv, "#netperf-run-form input[name='run[packet_length]'][value='1400']")
      assert has_element?(lv, "#netperf-run-form input[name='run[duration_sec]'][value='12']")

      # Editing target_address, target_port, and duration_sec preserves user values across render_change
      lv
      |> form("#netperf-run-form",
        run: %{
          "target_address" => "203.0.113.99",
          "target_port" => "6200",
          "duration_sec" => "18"
        }
      )
      |> render_change()

      assert has_element?(lv, "#netperf-run-form input[name='run[target_address]'][value='203.0.113.99']")
      assert has_element?(lv, "#netperf-run-form input[name='run[target_port]'][value='6200']")
      assert has_element?(lv, "#netperf-run-form input[name='run[duration_sec]'][value='18']")

      # Picking sender via searchable modal must still keep the user edits
      lv |> element("#netperf-run-sender-picker-trigger") |> render_click()

      lv
      |> element("#agent-picker-modal button[phx-click='agent_picker_select'][phx-value-uid='#{spoke_uid}']")
      |> render_click()

      assert has_element?(lv, "#netperf-run-form input[name='run[target_address]'][value='203.0.113.99']")
      assert has_element?(lv, "#netperf-run-form input[name='run[target_port]'][value='6200']")
      assert has_element?(lv, "#netperf-run-form input[name='run[duration_sec]'][value='18']")

      # Invalid numeric duration_sec shows error instead of coercing to default
      bad_run_html =
        lv
        |> form("#netperf-run-form", run: %{"duration_sec" => "abc"})
        |> render_submit()

      assert has_element?(lv, "#netperf-run-error")
      assert bad_run_html =~ "Duration (s)"
      refute_received {:netperf_run_dispatched, _, _, _}

      # Valid submit dispatches the preserved override values with refreshed actor
      lv
      |> form("#netperf-run-form", run: %{"duration_sec" => "18"})
      |> render_submit()

      assert_received {:netperf_run_dispatched, ^spoke_uid, dispatch_params, opts}
      assert opts[:actor].id == admin.id
      assert dispatch_params.responder_agent_id == hub2_uid
      assert dispatch_params.target_address == "203.0.113.99"
      assert dispatch_params.target_port == 6200
      assert dispatch_params.duration_sec == 18
      assert dispatch_params.protocol == "udp"
      assert dispatch_params.direction == "download"
    end

    test "Run Test Now modal dispatches netperf.run, handles PubSub updates, and surfaces errors",
         %{conn: conn} do
      spoke_uid = unique_uid("agent-spoke")
      hub_uid = unique_uid("agent-hub")
      register_agent!(spoke_uid, %{ip: "198.51.100.20"})
      register_agent!(hub_uid, %{ip: "198.51.100.21"})

      NetperfResponder.create_responder!(
        %{agent_uid: hub_uid, name: "Hub Target", advertise_address: "198.51.100.21"},
        actor: system_actor()
      )

      # 1. Real CommandBus error path: self-target and offline agent render readable errors without crashing
      {:ok, lv, _html} = live(conn, ~p"/settings/networks/netperf")

      lv |> element("#netperf-run-test-btn") |> render_click()
      assert has_element?(lv, "#netperf-run-modal")

      lv |> element("#netperf-run-sender-picker-trigger") |> render_click()

      lv
      |> element("#agent-picker-modal button[phx-click='agent_picker_select'][phx-value-uid='#{hub_uid}']")
      |> render_click()

      self_html =
        lv
        |> form("#netperf-run-form",
          run: %{
            "responder_agent_id" => hub_uid,
            "target_address" => "198.51.100.21",
            "target_port" => "5199"
          }
        )
        |> render_submit()

      assert self_html =~ "cannot be the same agent"

      lv |> element("#netperf-run-sender-picker-trigger") |> render_click()

      lv
      |> element("#agent-picker-modal button[phx-click='agent_picker_select'][phx-value-uid='#{spoke_uid}']")
      |> render_click()

      offline_html =
        lv
        |> form("#netperf-run-form",
          run: %{
            "responder_agent_id" => hub_uid,
            "target_address" => "198.51.100.21",
            "target_port" => "5199"
          }
        )
        |> render_submit()

      assert String.downcase(offline_html) =~ "offline" or
               String.downcase(offline_html) =~ "registry"

      # 2. Stubbed CommandBus success path + live PubSub ack/progress/result updates
      prev_bus = Application.get_env(:serviceradar_web_ng, :netperf_command_bus)
      cmd_id = Ecto.UUID.generate()
      :persistent_term.put({CommandBusStub, :test_pid}, self())
      :persistent_term.put({CommandBusStub, :result}, {:ok, cmd_id})
      Application.put_env(:serviceradar_web_ng, :netperf_command_bus, CommandBusStub)

      on_exit(fn ->
        :persistent_term.erase({CommandBusStub, :test_pid})
        :persistent_term.erase({CommandBusStub, :result})

        if is_nil(prev_bus) do
          Application.delete_env(:serviceradar_web_ng, :netperf_command_bus)
        else
          Application.put_env(:serviceradar_web_ng, :netperf_command_bus, prev_bus)
        end
      end)

      lv
      |> form("#netperf-run-form",
        run: %{
          "responder_agent_id" => hub_uid,
          "target_address" => "198.51.100.21",
          "target_port" => "5199",
          "protocol" => "udp",
          "direction" => "download",
          "bandwidth_bps" => "50000000",
          "duration_sec" => "5",
          "omit_sec" => "1",
          "parallel" => "2",
          "packet_length" => "1200"
        }
      )
      |> render_submit()

      assert_received {:netperf_run_dispatched, ^spoke_uid, dispatch_params, _opts}
      assert dispatch_params.responder_agent_id == hub_uid
      assert dispatch_params.protocol == "udp"
      assert dispatch_params.direction == "download"
      assert has_element?(lv, "#netperf-active-run-status")

      AgentCommandsPubSub.broadcast_persisted_ack(%{
        command_id: cmd_id,
        command_type: "netperf.run",
        message: "Accepted by spoke"
      })

      assert render(lv) =~ "ACKNOWLEDGED"

      AgentCommandsPubSub.broadcast_persisted_result(%{
        command_id: cmd_id,
        command_type: "netperf.run",
        success: true,
        message: "Completed",
        payload: %{"bits_per_second" => 49_000_000.0, "jitter_ms" => 0.31, "loss_percent" => 0.0}
      })

      final_html = render(lv)
      assert final_html =~ "COMPLETED"
      assert final_html =~ "49 Mbps"
      assert final_html =~ "0.31 ms"
    end
  end
end
