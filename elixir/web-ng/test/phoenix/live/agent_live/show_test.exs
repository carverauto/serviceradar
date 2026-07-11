defmodule ServiceRadarWebNGWeb.AgentLive.ShowTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.AgentLive.Show

  setup %{conn: conn} do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "admin sees release-management handoff actions on the agent detail page", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Release Management"
    assert html =~ "Roll Out This Agent"
    assert html =~ "Manage Releases"
    assert html =~ "cohort=custom"
    assert html =~ "agent_ids=agent-1"
    assert html =~ "version=2.0.0"
  end

  test "viewer can inspect agent detail but does not see rollout actions", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Release Management"
    refute html =~ "Roll Out This Agent"
    refute html =~ "Manage Releases"
  end

  test "operator sees service checks assigned to the agent", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    gateway = gateway_fixture(%{id: "gw-1", component_id: "component-agent-show-service-checks"})
    agent_fixture(gateway, %{uid: "agent-1", name: "Alpha"})

    service_check_fixture(%{
      name: "PVE API 8006",
      check_type: :tcp,
      target: "192.168.2.10",
      port: 8006,
      interval_seconds: 30,
      agent_uid: "agent-1"
    })

    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Direct service checks"
    assert html =~ "PVE API 8006"
    assert html =~ "192.168.2.10"
    assert html =~ "30s"
    refute html =~ "No direct service checks are assigned."
  end

  test "empty direct-check state distinguishes checks from add-on and plugin work", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Direct service checks"
    assert html =~ "Ping, TCP, HTTP, DNS, and gRPC checks assigned directly to this agent"
    assert html =~ "No direct service checks are assigned."
    assert html =~ "Add-on and plugin work is reported in the sections above."
  end

  test "network visibility card surfaces kernel BPF availability" do
    agent = %{
      "capabilities" => ["host-network-visibility.flow_attribution.enabled"],
      "metadata" => %{
        "sidecars" => [
          %{"name" => "netprobe", "state" => "running", "pid" => 12_345, "restart_count" => 0}
        ]
      }
    }

    html = render_component(&Show.network_visibility_card/1, agent: agent)

    assert html =~ "Kernel BPF"
    assert html =~ "BPF available"
    assert html =~ "available"
    refute html =~ "degraded"
  end

  test "network visibility card maps legacy degraded BPF payloads to unavailable" do
    agent = %{
      "capabilities" => ["host-network-visibility.flow_attribution.enabled"],
      "metadata" => %{
        "host_network_visibility" => %{"bpf" => "degraded"},
        "sidecars" => [
          %{"name" => "netprobe", "state" => "running"}
        ]
      }
    }

    html = render_component(&Show.network_visibility_card/1, agent: agent)

    assert html =~ "Kernel BPF"
    assert html =~ "BPF unavailable"
    refute html =~ "BPF degraded"
    refute html =~ ">degraded<"
  end

  test "config apply card shows per-section statuses and the failing error verbatim" do
    config_status = %{
      health: :unhealthy,
      acked_version: "cfg-v2",
      acked_at: ~U[2026-07-04 10:00:00Z],
      pushed_version: "cfg-v3",
      pushed_at: ~U[2026-07-04 09:00:00Z],
      sections: [
        %{"section" => "bumblebee", "disposition" => "success", "error" => "", "since" => nil},
        %{
          "section" => "visibility",
          "disposition" => "permanent_failure",
          "error" =>
            "merge netprobe add-on config: json: cannot unmarshal string into Go struct field " <>
              "addonConfig.capture_interfaces of type []string",
          "since" => "2026-07-01T00:44:00Z"
        }
      ]
    }

    html = render_component(&Show.config_apply_card/1, config_status: config_status)

    assert html =~ "Config Apply"
    assert html =~ "config unhealthy"
    assert html =~ "cfg-v2"
    # Pushed-but-unacked version is surfaced.
    assert html =~ "Pushed, Not Yet Acked"
    assert html =~ "cfg-v3"
    # Section detail: name, disposition badge, error verbatim, since.
    assert html =~ "visibility"
    assert html =~ "permanent failure"
    assert html =~ "capture_interfaces of type []string"
    assert html =~ "2026-07-01"
    assert html =~ "bumblebee"
  end

  test "config apply card renders a placeholder without ack data" do
    html = render_component(&Show.config_apply_card/1, config_status: nil)

    assert html =~ "No config acknowledgement data recorded yet."
  end

  test "config apply card notes legacy whole-version acks" do
    config_status = %{
      health: :healthy,
      acked_version: "cfg-v1",
      acked_at: ~U[2026-07-04 10:00:00Z],
      pushed_version: "cfg-v1",
      pushed_at: ~U[2026-07-04 09:00:00Z],
      sections: []
    }

    html = render_component(&Show.config_apply_card/1, config_status: config_status)

    assert html =~ "legacy whole-version acks"
    refute html =~ "Pushed, Not Yet Acked"
  end

  test "add-on drift card surfaces unhealthy and architecture-unsupported add-ons", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    unhealthy_package =
      create_approved_addon_package!(%{
        addon_id: "netprobe-unhealthy",
        name: "Netprobe Unhealthy",
        artifacts: %{"linux/arm64" => %{"object_key" => "netprobe-arm64.tar"}}
      })

    unsupported_package =
      create_approved_addon_package!(%{
        addon_id: "netprobe-unsupported",
        name: "Netprobe Unsupported",
        artifacts: %{"linux/amd64" => %{"object_key" => "netprobe-amd64.tar"}}
      })

    create_addon_assignment!("agent-1", unhealthy_package.id)
    create_addon_assignment!("agent-1", unsupported_package.id)

    report_addon_status!("agent-1", "netprobe-unhealthy", %{
      state: "unhealthy",
      active: false,
      degradation_reason: "health probe failed",
      arch: "arm64"
    })

    report_addon_status!("agent-1", "netprobe-unsupported", %{
      state: "running",
      active: true,
      arch: "arm64"
    })

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Add-on status"
    assert html =~ "Netprobe Unhealthy"
    assert html =~ "unhealthy"
    assert html =~ "health probe failed"
    assert html =~ "Netprobe Unsupported"
    assert html =~ "arch unsupported"
  end

  test "required runtimes and active resource-limit warnings are represented honestly", %{conn: conn} do
    old_required_addons = Application.get_env(:serviceradar_core, :required_agent_addons)
    Application.put_env(:serviceradar_core, :required_agent_addons, ["otel-collector"])

    on_exit(fn ->
      if is_nil(old_required_addons) do
        Application.delete_env(:serviceradar_core, :required_agent_addons)
      else
        Application.put_env(:serviceradar_core, :required_agent_addons, old_required_addons)
      end
    end)

    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    report_addon_status!("agent-1", "otel-collector", %{
      state: "running",
      active: true,
      version: "0.1.1",
      degradation_reason: "resource limits not enforced: create addon cgroup root: permission denied"
    })

    report_addon_status!("agent-1", "advisory-producer", %{
      state: "running",
      active: true,
      version: "0.1.0"
    })

    {:ok, lv, _html} = live(conn, ~p"/agents/agent-1")
    addons_html = lv |> element("#addons") |> render()

    assert addons_html =~ "required runtime"
    assert addons_html =~ "running with warning"
    assert addons_html =~ "resource limits not enforced"
    refute addons_html =~ "advisory-producer"
    refute addons_html =~ ">unhealthy<"
  end

  test "unavailable capability markers are collapsed away from active capabilities", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Capabilities"
    assert html =~ "Unavailable capability markers"
    assert html =~ "host-network-visibility.dpi.unavailable"
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      {:ok,
       %{
         "results" => sample_agents(query),
         "pagination" => %{},
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp sample_agents(query) do
      if String.contains?(query, ~s(uid:"agent-1")) do
        [
          %{
            "uid" => "agent-1",
            "name" => "Alpha",
            "gateway_id" => "gw-1",
            "version" => "1.2.3",
            "desired_version" => "2.0.0",
            "release_rollout_state" => "failed",
            "last_update_error" => "digest mismatch",
            "last_update_at" => "2026-03-27T18:02:00Z",
            "last_seen_time" => "2026-03-27T18:03:00Z",
            "metadata" => %{"os" => "linux", "arch" => "arm64"},
            "capabilities" => [
              "agent",
              "host-network-visibility",
              "host-network-visibility.dpi.unavailable"
            ]
          }
        ]
      else
        []
      end
    end
  end

  defp create_approved_addon_package!(attrs) do
    defaults = %{
      addon_id: "addon-#{System.unique_integer([:positive])}",
      name: "Agent Detail Add-on",
      version: "1.0.0",
      description: "Agent detail test add-on",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-addon",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: ["addon.run"],
      config_schema: %{},
      artifacts: %{},
      requires: %{},
      source_type: :first_party,
      source_oci_ref: "registry.carverauto.dev/serviceradar/addon:test",
      source_oci_digest: "sha256:test",
      source_release_tag: "v1.0.0",
      source_metadata: %{},
      imported_at: DateTime.utc_now(),
      verification_status: "verified"
    }

    package =
      AddonPackage
      |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
      |> Ash.create!()

    package
    |> Ash.Changeset.for_update(:approve, %{approved_capabilities: package.capabilities}, actor: system_actor())
    |> Ash.update!()
  end

  defp create_addon_assignment!(agent_uid, package_id) do
    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{agent_uid: agent_uid, addon_package_id: package_id, params: %{}, args: []},
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp report_addon_status!(agent_uid, addon_id, attrs) do
    AddonStatus
    |> Ash.Changeset.for_create(
      :report,
      Map.merge(
        %{
          agent_uid: agent_uid,
          addon_id: addon_id,
          state: "running",
          active: true,
          reported_at: DateTime.utc_now()
        },
        attrs
      ),
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
