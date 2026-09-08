defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntime

  @moduletag :db_free

  defmodule StubCommandBus do
    @moduledoc false
    def dispatch_endpoint_inventory_cache_query(agent_id, payload, opts) do
      send(self(), {:cache_query, agent_id, payload, opts})
      {:ok, "cache-command-1"}
    end

    def dispatch_endpoint_inventory_force_fresh_scan(agent_id, payload, opts) do
      send(self(), {:force_fresh, agent_id, payload, opts})
      {:ok, "fresh-command-1"}
    end

    def dispatch_endpoint_inventory_cohort_cache_query(payload, opts) do
      send(self(), {:cohort_query, payload, opts})

      {:ok,
       %{
         query_id: "cohort-query-1",
         coverage: %{targeted: 2, answered: 1, offline: 1, expired: 0, pending: 0},
         results: [
           %{
             "agent_id" => "agent-1",
             "device_uid" => "sr:test-device",
             "matched" => true,
             "freshness" => %{"verdict" => "fresh"}
           }
         ],
         dispatches: []
       }}
    end
  end

  test "dispatches a device cache query with bounded predicate payload" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_device_query(
        %{"name" => "nginx", "package_manager" => "dpkg", "mode" => "detail"},
        command_bus: StubCommandBus
      )

    assert_receive {:cache_query, "agent-1", payload, opts}
    assert payload.predicate == %{name: "nginx", package_manager: "dpkg"}
    assert payload.mode == "detail"
    assert payload.limit == 25
    assert opts[:context].device_uid == "sr:test-device"
    assert socket.assigns.endpoint_inventory_query_running == true

    assert MapSet.member?(
             socket.assigns.endpoint_inventory_pending_command_ids,
             "cache-command-1"
           )
  end

  test "dispatches force fresh scan through guarded command path" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_force_refresh(
        %{"name" => "nginx", "package_manager" => "dpkg"},
        command_bus: StubCommandBus
      )

    assert_receive {:force_fresh, "agent-1", payload, opts}
    assert payload.sources == ["os_packages"]
    assert payload.query.predicate == %{name: "nginx", package_manager: "dpkg"}
    assert opts[:context].device_uid == "sr:test-device"
    assert socket.assigns.endpoint_inventory_force_refresh_running == true
  end

  test "dispatches cohort query and stores coverage envelope" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_cohort_query(
        %{"name" => "nginx", "cohort" => "custom", "agent_ids" => "agent-1, agent-2"},
        command_bus: StubCommandBus
      )

    assert_receive {:cohort_query, payload, opts}
    assert payload.predicate == %{name: "nginx"}
    assert payload.mode == "count"
    assert opts[:agent_ids] == ["agent-1", "agent-2"]
    assert socket.assigns.endpoint_inventory_cohort_query_result.coverage.answered == 1
    assert socket.assigns.endpoint_inventory_cohort_query_result.coverage.offline == 1
  end

  test "package filter form change resets to first page" do
    socket =
      socket()
      |> Map.update!(:assigns, &Map.put(&1, :device_uid, nil))
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(:assigns, &Map.put(&1, :endpoint_inventory_package_page, 4))
      |> EndpointInventoryRuntime.apply_package_filter(%{"q" => "nginx"})

    assert socket.assigns.endpoint_inventory_package_filter_form.params["q"] == "nginx"
    # device_uid is nil here so the reload is a no-op, but the page must reset.
    assert socket.assigns.endpoint_inventory_package_page == 1
  end

  test "package page navigation is clamped to at least page 1" do
    socket =
      socket()
      |> Map.update!(:assigns, &Map.put(&1, :device_uid, nil))
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &(&1
          |> Map.put(:endpoint_inventory_package_total, 250)
          |> Map.put(:endpoint_inventory_package_page_size, 100))
      )
      |> EndpointInventoryRuntime.change_package_page("0")

    assert socket.assigns.endpoint_inventory_package_page == 1
  end

  test "opens the package detail modal for a loaded row" do
    package = %{
      id: "pkg-1",
      name: "nginx",
      version: "1.18.0",
      package_manager: "dpkg",
      endpoint_package_ref: "epr-1"
    }

    socket =
      socket()
      # device_uid nil makes the vulnerability load a no-op (empty list).
      |> Map.update!(:assigns, &Map.put(&1, :device_uid, nil))
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(:assigns, &Map.put(&1, :endpoint_inventory_packages, [package]))
      |> EndpointInventoryRuntime.open_package_detail("pkg-1")

    assert socket.assigns.show_endpoint_inventory_package_modal == true
    assert socket.assigns.endpoint_inventory_selected_package.id == "pkg-1"
    assert socket.assigns.endpoint_inventory_selected_package_assessment_details.assessments == []
  end

  test "ignores open request for an unknown package id" do
    socket =
      socket()
      |> Map.update!(:assigns, &Map.put(&1, :device_uid, nil))
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(:assigns, &Map.put(&1, :endpoint_inventory_packages, [%{id: "pkg-1"}]))
      |> EndpointInventoryRuntime.open_package_detail("missing")

    assert socket.assigns.show_endpoint_inventory_package_modal == false
    assert socket.assigns.endpoint_inventory_selected_package == nil
  end

  test "closes the package detail modal and clears the selection" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &(&1
          |> Map.put(:show_endpoint_inventory_package_modal, true)
          |> Map.put(:endpoint_inventory_selected_package, %{id: "pkg-1"})
          |> Map.put(:endpoint_inventory_selected_package_assessment_details, %{
            assessments: [%{id: "assessment-1"}],
            supporting_matches: [],
            supporting_matches_total: 0,
            supporting_matches_truncated?: false
          }))
      )
      |> EndpointInventoryRuntime.close_package_detail()

    assert socket.assigns.show_endpoint_inventory_package_modal == false
    assert socket.assigns.endpoint_inventory_selected_package == nil
    assert socket.assigns.endpoint_inventory_selected_package_assessment_details.assessments == []
  end

  test "opens the match detail modal from a loaded assessment row" do
    assessment = %{
      id: "assessment-starling",
      cve_id: "CVE-2099-4101",
      advisory_id: "CVE-2099-4101",
      status: "active",
      assessment: "confirmed",
      disposition: "affected",
      authority: "ubuntu:USN-2099-4101-1",
      applicability_reason: "exact synthetic distro package range",
      freshness: "fresh",
      provider: "ubuntu",
      feed_key: "ubuntu-usn",
      kev: true,
      package_name: "starling-fetch",
      package_manager: "dpkg",
      installed_version: "3.2.1-1ubuntu99.7",
      supporting_match_ids: []
    }

    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &Map.put(&1, :endpoint_inventory_vulnerability_assessments, %{
          confirmed: %{rows: [assessment], total: 1},
          candidates: %{rows: [], total: 0},
          history: %{rows: [], total: 0}
        })
      )
      |> EndpointInventoryRuntime.open_match_detail("assessment-starling")

    assert socket.assigns.show_endpoint_inventory_match_modal == true
    group = socket.assigns.endpoint_inventory_selected_match_group
    assert group.package_name == "starling-fetch"
    assert Enum.map(group.advisories, & &1.cve_id) == ["CVE-2099-4101"]
  end

  test "ignores open request for an unknown assessment id" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &Map.put(&1, :endpoint_inventory_vulnerability_assessments, %{
          confirmed: %{rows: [%{id: "assessment-quartz", package_name: "quartz"}], total: 1},
          candidates: %{rows: [], total: 0},
          history: %{rows: [], total: 0}
        })
      )
      |> EndpointInventoryRuntime.open_match_detail("missing")

    assert socket.assigns.show_endpoint_inventory_match_modal == false
    assert socket.assigns.endpoint_inventory_selected_match_group == nil
  end

  test "closes the match detail modal and clears the selection" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &(&1
          |> Map.put(:show_endpoint_inventory_match_modal, true)
          |> Map.put(:endpoint_inventory_selected_match_group, %{id: "pkg-1"}))
      )
      |> EndpointInventoryRuntime.close_match_detail()

    assert socket.assigns.show_endpoint_inventory_match_modal == false
    assert socket.assigns.endpoint_inventory_selected_match_group == nil
  end

  test "applies relevant command result with freshness payload" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(
        :assigns,
        &Map.put(&1, :endpoint_inventory_pending_command_ids, MapSet.new(["cmd-1"]))
      )
      |> EndpointInventoryRuntime.apply_command_update(:result, %{
        command_id: "cmd-1",
        command_type: "endpoint_inventory.cache_query",
        success: true,
        payload: %{
          "matched" => true,
          "match_count" => 1,
          "freshness" => %{"verdict" => "fresh"}
        }
      })

    assert socket.assigns.endpoint_inventory_live_query_result["matched"] == true
    assert socket.assigns.endpoint_inventory_live_query_result["freshness"]["verdict"] == "fresh"
    refute MapSet.member?(socket.assigns.endpoint_inventory_pending_command_ids, "cmd-1")
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: %{user: %{id: "user-1"}},
        device_uid: "sr:test-device",
        device_row: %{"partition_id" => "default", "agent_id" => "agent-1"},
        endpoint_inventory_scan: %{agent_id: "agent-1"},
        results: [%{"agent_id" => "agent-1"}]
      }
    }
  end
end
