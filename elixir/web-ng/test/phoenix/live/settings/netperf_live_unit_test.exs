defmodule ServiceRadarWebNGWeb.Settings.NetperfLiveUnitTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
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

    test "format_dispatch_error/1 translates every CommandBus netperf error reason" do
      assert Forms.format_dispatch_error(:netperf_responder_disabled) =~ "disabled"
      assert Forms.format_dispatch_error(:netperf_self_target_forbidden) =~ "same agent"
      assert Forms.format_dispatch_error(:invalid_authority_epoch) =~ "authority epoch"
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
