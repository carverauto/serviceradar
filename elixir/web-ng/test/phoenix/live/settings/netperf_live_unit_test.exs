defmodule ServiceRadarWebNGWeb.Settings.NetperfLiveUnitTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Data
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Forms
  alias ServiceRadarWebNGWeb.Settings.NetperfLive.Index

  @moduletag :db_free

  defp disconnected_socket(scope, live_action \\ :index) do
    %Socket{
      assigns: %{
        __changed__: %{},
        current_scope: scope,
        live_action: live_action,
        flash: %{}
      },
      private: %{
        live_temp: %{},
        lifecycle: %Lifecycle{}
      }
    }
  end

  defp permitted_scope do
    %Scope{user: nil, permissions: MapSet.new(["settings.networks.manage"])}
  end

  defp unpermitted_scope do
    %Scope{user: nil, permissions: MapSet.new(["devices.view"])}
  end

  describe "supported_tabs/0 and RBAC / Iron Laws" do
    test "exports supported_tabs/0 matching Settings.Catalog" do
      assert Index.supported_tabs() == ~w(policies responders profiles)
    end

    test "unauthorized mount redirects to /settings/profile with flash error" do
      socket = disconnected_socket(unpermitted_scope())

      assert {:ok, redirected} = Index.mount(%{}, %{}, socket)
      assert {:redirect, %{to: "/settings/profile"}} = redirected.redirected
      assert redirected.assigns.flash["error"] =~ "Not authorized"
    end

    test "disconnected mount and handle_params perform zero DB queries and leave loading? true" do
      socket = disconnected_socket(permitted_scope())

      assert {:ok, mounted} = Index.mount(%{}, %{}, socket)
      assert mounted.assigns.loading? == true
      assert mounted.assigns.policies_count == 0
      assert mounted.assigns.responders_count == 0
      assert mounted.assigns.profiles_count == 0
      assert mounted.assigns.recent_runs_count == 0
      assert Map.has_key?(mounted.assigns.streams, :policies)
      assert Map.has_key?(mounted.assigns.streams, :responders)
      assert Map.has_key?(mounted.assigns.streams, :profiles)
      assert Map.has_key?(mounted.assigns.streams, :recent_runs)

      assert {:noreply, after_params} =
               Index.handle_params(%{"tab" => "responders"}, "/settings/networks/netperf", mounted)

      assert after_params.assigns.active_tab == "responders"
      assert after_params.assigns.loading? == true
    end

    test "unauthorized handle_params redirects to /settings/profile" do
      socket = disconnected_socket(unpermitted_scope())

      assert {:noreply, denied} =
               Index.handle_params(%{}, "/settings/networks/netperf", socket)

      assert {:redirect, %{to: "/settings/profile"}} = denied.redirected
    end

    test "disconnected handle_params uses cached scope without DB queries even when user struct is present" do
      scope = %Scope{
        user: %{id: Ecto.UUID.generate(), role: :viewer},
        permissions: MapSet.new(["settings.networks.manage"])
      }

      {:ok, mounted} = Index.mount(%{}, %{}, disconnected_socket(scope))

      assert {:noreply, after_params} =
               Index.handle_params(%{"tab" => "profiles"}, "/settings/networks/netperf", mounted)

      assert after_params.assigns.active_tab == "profiles"
      assert after_params.assigns.loading? == true
    end

    test "handle_event denies unauthenticated or unbacked scope via RBAC.authorize_current" do
      socket = disconnected_socket(permitted_scope())

      assert {:noreply, denied} =
               Index.handle_event("open_run_modal", %{}, socket)

      assert {:redirect, %{to: "/settings/profile"}} = denied.redirected
      assert denied.assigns.flash["error"] =~ "Not authorized"
    end
  end

  describe "Forms spoke_selector, bps, and preset helpers" do
    test "build_spoke_selector/1 normalizes partition, tags, srql_query, and agent_uids" do
      selector =
        Forms.build_spoke_selector(%{
          "spoke_partition_id" => "  farm01 ",
          "spoke_tags_text" => "site=branch-1, tier = edge\nenv=prod",
          "spoke_srql_query" => " in:agents status:connected ",
          "spoke_agent_uids_text" => "agent-1, agent-2\nagent-1"
        })

      assert selector == %{
               "partition_id" => "farm01",
               "tags" => %{"site" => "branch-1", "tier" => "edge", "env" => "prod"},
               "srql_query" => "in:agents status:connected",
               "agent_uids" => ["agent-1", "agent-2"]
             }

      assert Forms.build_spoke_selector(%{
               "spoke_partition_id" => "  ",
               "spoke_tags_text" => "",
               "spoke_srql_query" => "",
               "spoke_agent_uids_text" => ""
             }) == %{}
    end

    test "build_policy_attrs/1 clears spoke_selector for hub_mesh and deduplicates responder_ids" do
      {attrs, responder_ids} =
        Forms.build_policy_attrs(%{
          "name" => "  Backbone Mesh  ",
          "mode" => "hub_mesh",
          "enabled" => "true",
          "profile_id" => "prof-1",
          "responder_ids" => ["", "resp-1", "resp-2", "resp-1"],
          "spoke_partition_id" => "should-be-ignored"
        })

      assert attrs.name == "Backbone Mesh"
      assert attrs.mode == :hub_mesh
      assert attrs.spoke_selector == %{}
      assert responder_ids == ["resp-1", "resp-2"]
    end

    test "format_bps/1 formats Gbps, Mbps, Kbps, and bps" do
      assert Forms.format_bps(1_000_000_000) == "1 Gbps"
      assert Forms.format_bps(50_000_000) == "50 Mbps"
      assert Forms.format_bps(500_000) == "500 Kbps"
      assert Forms.format_bps(800) == "800 bps"
      assert Forms.format_bps(nil) == "—"
    end

    test "apply_run_presets/4 populates responder target and profile parameters" do
      responders = [
        %{
          agent_uid: "agent-hub-1",
          advertise_address: "198.51.100.10",
          listen_port: 5199,
          agent: %{ip: "192.0.2.10", host: "hub-1"}
        }
      ]

      profiles = [
        %{
          id: "prof-udp",
          protocol: :udp,
          direction: :bidirectional,
          bandwidth_bps: 25_000_000,
          duration_sec: 10,
          omit_sec: 2,
          parallel: 4,
          packet_length: 1400
        }
      ]

      merged =
        Forms.apply_run_presets(
          %{"responder_agent_id" => "agent-hub-1", "profile_id" => "prof-udp"},
          responders,
          profiles,
          &Data.resolve_responder_address/1
        )

      assert merged["target_address"] == "198.51.100.10"
      assert merged["target_port"] == "5199"
      assert merged["protocol"] == "udp"
      assert merged["direction"] == "bidirectional"
      assert merged["bandwidth_bps"] == "25000000"
      assert merged["duration_sec"] == "10"
      assert merged["omit_sec"] == "2"
      assert merged["parallel"] == "4"
      assert merged["packet_length"] == "1400"
    end

    test "apply_run_presets preserves user-edited overrides unless responder or profile changed" do
      responders = [
        %{
          agent_uid: "hub-1",
          advertise_address: "198.51.100.10",
          listen_port: 5199,
          agent: nil
        },
        %{
          agent_uid: "hub-2",
          advertise_address: "198.51.100.20",
          listen_port: 5201,
          agent: nil
        }
      ]

      profiles = [
        %{
          id: "prof-1",
          protocol: :tcp,
          direction: :upload,
          bandwidth_bps: 50_000_000,
          duration_sec: 5,
          omit_sec: 1,
          parallel: 1,
          packet_length: 1200
        },
        %{
          id: "prof-2",
          protocol: :udp,
          direction: :download,
          bandwidth_bps: 20_000_000,
          duration_sec: 12,
          omit_sec: 2,
          parallel: 2,
          packet_length: 1400
        }
      ]

      # 4-arity call preserves explicit non-blank user values.
      preserved_4 =
        Forms.apply_run_presets(
          %{
            "responder_agent_id" => "hub-1",
            "target_address" => "203.0.113.99",
            "target_port" => "6200",
            "profile_id" => "prof-1",
            "protocol" => "udp",
            "duration_sec" => "15"
          },
          responders,
          profiles,
          &Data.resolve_responder_address/1
        )

      assert preserved_4["target_address"] == "203.0.113.99"
      assert preserved_4["target_port"] == "6200"
      assert preserved_4["protocol"] == "udp"
      assert preserved_4["duration_sec"] == "15"
      assert preserved_4["direction"] == "upload"

      prev = %{
        "responder_agent_id" => "hub-1",
        "target_address" => "198.51.100.10",
        "target_port" => "5199",
        "profile_id" => "prof-1",
        "protocol" => "tcp",
        "direction" => "upload",
        "bandwidth_bps" => "50000000",
        "duration_sec" => "5",
        "omit_sec" => "1",
        "parallel" => "1",
        "packet_length" => "1200"
      }

      # Editing target_address or duration_sec preserves user input.
      edited =
        Forms.apply_run_presets(
          Map.merge(prev, %{
            "target_address" => "203.0.113.99",
            "target_port" => "6200",
            "protocol" => "udp",
            "duration_sec" => "15"
          }),
          responders,
          profiles,
          &Data.resolve_responder_address/1,
          target: ["run", "duration_sec"],
          prev_params: prev
        )

      assert edited["target_address"] == "203.0.113.99"
      assert edited["target_port"] == "6200"
      assert edited["protocol"] == "udp"
      assert edited["duration_sec"] == "15"

      # Changing responder_agent_id updates target_address & target_port without clobbering profile edits.
      switched_responder =
        Forms.apply_run_presets(
          Map.put(edited, "responder_agent_id", "hub-2"),
          responders,
          profiles,
          &Data.resolve_responder_address/1,
          target: ["run", "responder_agent_id"],
          prev_params: edited
        )

      assert switched_responder["target_address"] == "198.51.100.20"
      assert switched_responder["target_port"] == "5201"
      assert switched_responder["protocol"] == "udp"
      assert switched_responder["duration_sec"] == "15"

      # Changing profile_id updates profile fields without clobbering target_address/port.
      with_custom_target = Map.merge(switched_responder, %{"target_address" => "203.0.113.77", "target_port" => "7000"})

      switched_profile =
        Forms.apply_run_presets(
          Map.put(with_custom_target, "profile_id", "prof-2"),
          responders,
          profiles,
          &Data.resolve_responder_address/1,
          target: ["run", "profile_id"],
          prev_params: with_custom_target
        )

      assert switched_profile["target_address"] == "203.0.113.77"
      assert switched_profile["target_port"] == "7000"
      assert switched_profile["protocol"] == "udp"
      assert switched_profile["direction"] == "download"
      assert switched_profile["duration_sec"] == "12"
      assert switched_profile["bandwidth_bps"] == "20000000"

      # Actively clearing target_address does not snap back while target_address is the _target.
      cleared_target =
        Forms.apply_run_presets(
          Map.put(prev, "target_address", ""),
          responders,
          profiles,
          &Data.resolve_responder_address/1,
          target: ["run", "target_address"],
          prev_params: prev
        )

      assert cleared_target["target_address"] == ""
    end

    test "build_profile_attrs, build_responder_attrs, and build_run_params do not silently coerce malformed/blank integers" do
      bad_profile_attrs =
        Forms.build_profile_attrs(%{
          "name" => "bad-nums",
          "bandwidth_bps" => "not-a-num",
          "duration_sec" => "abc",
          "omit_sec" => "1.5",
          "parallel" => "",
          "packet_length" => "1200",
          "interval_seconds" => "900"
        })

      assert bad_profile_attrs.bandwidth_bps == "not-a-num"
      assert bad_profile_attrs.duration_sec == "abc"
      assert bad_profile_attrs.omit_sec == "1.5"
      assert bad_profile_attrs.parallel == nil

      profile_cs = Ash.Changeset.for_create(NetperfProfile, :create, bad_profile_attrs)
      refute profile_cs.valid?

      bad_responder_attrs =
        Forms.build_responder_attrs(%{
          "agent_uid" => "hub-1",
          "name" => "Hub One",
          "listen_port" => "1.5",
          "max_concurrent_sessions" => "abc",
          "max_total_bandwidth_bps" => ""
        })

      assert bad_responder_attrs.listen_port == "1.5"
      assert bad_responder_attrs.max_concurrent_sessions == "abc"
      assert bad_responder_attrs.max_total_bandwidth_bps == nil

      responder_cs = Ash.Changeset.for_create(NetperfResponder, :create, bad_responder_attrs)
      refute responder_cs.valid?

      valid_run_base = %{
        "responder_agent_id" => "hub-1",
        "target_address" => "198.51.100.10",
        "target_port" => "5199",
        "protocol" => "tcp",
        "direction" => "upload",
        "bandwidth_bps" => "50000000",
        "duration_sec" => "5",
        "omit_sec" => "1",
        "parallel" => "1",
        "packet_length" => "1200"
      }

      assert {:ok, parsed_run} = Forms.build_run_params(valid_run_base)
      assert parsed_run.target_port == 5199
      assert parsed_run.duration_sec == 5

      for {field, bad_val} <- [
            {"target_port", "abc"},
            {"target_port", "1.5"},
            {"target_port", ""},
            {"duration_sec", "abc"},
            {"bandwidth_bps", "1.5"},
            {"omit_sec", ""},
            {"parallel", "99"},
            {"packet_length", "10"}
          ] do
        assert {:error, reason} = Forms.build_run_params(Map.put(valid_run_base, field, bad_val))
        assert Forms.format_dispatch_error(reason) =~ ~r/integer|between/i
      end
    end

    test "policy_to_form_params guards %Ash.NotLoaded{} on :responders" do
      policy = %{
        name: "Unloaded Responders Policy",
        description: nil,
        enabled: true,
        mode: :hub_and_spoke,
        profile_id: "prof-1",
        spoke_selector: %{},
        responders: %Ash.NotLoaded{type: :relationship, field: :responders}
      }

      params = Forms.policy_to_form_params(policy)
      assert params["responder_ids"] == []
    end

    test "format_dispatch_error/1 translates every CommandBus netperf error reason" do
      assert Forms.format_dispatch_error(:netperf_responder_disabled) =~ "disabled"
      assert Forms.format_dispatch_error(:netperf_self_target_forbidden) =~ "same agent"
      assert Forms.format_dispatch_error(:invalid_authority_epoch) =~ "authority epoch"
      assert Forms.format_dispatch_error(:invalid_form_state) =~ "no longer active"
      assert Forms.format_dispatch_error({:agent_offline, "a-1"}) =~ "a-1 is offline"

      assert Forms.format_dispatch_error({:agent_capability_missing, "a-1", "netperf"}) =~
               "netperf"

      assert Forms.format_dispatch_error({:agent_busy, :netperf_run_running}) =~ "active"
    end
  end

  describe "Data.resolve_responder_address/1 and PubSub command state machine" do
    test "resolve_responder_address/1 prefers advertise_address then agent.ip then agent.host" do
      assert Data.resolve_responder_address(%{
               advertise_address: "198.51.100.99",
               agent: %{ip: "192.0.2.1", host: "hub.example"}
             }) == "198.51.100.99"

      assert Data.resolve_responder_address(%{
               advertise_address: "   ",
               agent: %{ip: "192.0.2.1", host: "hub.example"}
             }) == "192.0.2.1"

      assert Data.resolve_responder_address(%{
               advertise_address: nil,
               agent: %{ip: nil, host: "hub.example"}
             }) == "hub.example"

      assert Data.resolve_responder_address(%{advertise_address: nil, agent: nil}) == nil
    end

    test "handle_info updates active_run across ack, progress, and terminal result" do
      {:ok, socket} = Index.mount(%{}, %{}, disconnected_socket(permitted_scope()))
      command_id = "cmd-netperf-unit-1"

      socket =
        Phoenix.Component.assign(socket, :active_run, %{
          command_id: command_id,
          sender_agent_id: "agent-spoke-1",
          responder_agent_id: "agent-hub-1",
          target_address: "198.51.100.10",
          target_port: 5199,
          protocol: "tcp",
          direction: "upload",
          state: :sent,
          progress_percent: nil,
          message: "Dispatched",
          result_payload: nil
        })

      {:noreply, socket} =
        Index.handle_info(
          {:command_ack, %{command_id: command_id, command_type: "netperf.run", message: "Accepted"}},
          socket
        )

      assert socket.assigns.active_run.state == :acknowledged
      assert socket.assigns.active_run.message == "Accepted"

      {:noreply, socket} =
        Index.handle_info(
          {:command_progress,
           %{
             command_id: command_id,
             command_type: "netperf.run",
             progress_percent: 50,
             message: "Streaming"
           }},
          socket
        )

      assert socket.assigns.active_run.state == :running
      assert socket.assigns.active_run.progress_percent == 50
      assert socket.assigns.active_run.message == "Streaming (50%)"

      {:noreply, socket} =
        Index.handle_info(
          {:command_result,
           %{
             command_id: command_id,
             command_type: "netperf.run",
             success: true,
             message: "Completed",
             payload: %{"bits_per_second" => 48_500_000.0, "jitter_ms" => 0.42}
           }},
          socket
        )

      assert socket.assigns.active_run.state == :completed
      assert socket.assigns.active_run.result_payload["bits_per_second"] == 48_500_000.0

      # Unrelated command updates must not overwrite active_run.
      {:noreply, unchanged} =
        Index.handle_info(
          {:command_result, %{command_id: "other-cmd", command_type: "netperf.run", success: false}},
          socket
        )

      assert unchanged.assigns.active_run.state == :completed
    end
  end
end
