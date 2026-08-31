defmodule ServiceRadarWebNGWeb.SecurityDashboardRoutesTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  setup :register_and_log_in_user

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)

    on_exit(fn ->
      if is_nil(old_srql_module) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      end
    end)

    actor = SystemActor.system(:first_party_dashboard_route_test)

    assert {:ok, %{packages: seeded}} = FirstPartyPackages.seed_all(actor: actor)
    assert Enum.count(seeded) >= 3

    :ok
  end

  test "security page is reachable and links to the packaged security dashboard", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/security")
    html = render_async(view, 5_000) <> html

    assert html =~ "Security analytics workbench"
    assert html =~ "without loading duplicate dashboard frames"
    assert html =~ "Live Posture"
    assert html =~ "Recent findings"
    assert html =~ "Critical / High"
    assert html =~ "Terminal shell in container"
    assert html =~ "Critical / High Findings"
    refute html =~ "Routine medium finding"
    assert has_element?(view, "a[href='/events/falco-event-1']", "Terminal shell in container")
    assert has_element?(view, "a[href='/dashboards/security-findings']", "Security Findings")
    assert has_element?(view, "a[href*='in%3Asecurity_findings'][href*='limit%3A25']", "Open findings")
    assert has_element?(view, "a[href='/settings/security/vulnerability-feeds']", "Advisory Feeds")
  end

  test "security page renders normalized Trivy finding detail deep links", %{conn: conn} do
    event_uuid = Ecto.UUID.generate()
    finding_uuid = Ecto.UUID.generate()

    insert_trivy_finding!(event_uuid, finding_uuid)

    {:ok, detail_view, _html} = live(conn, ~p"/security?#{%{finding: finding_uuid}}")
    detail_html = render_async(detail_view, 5_000)

    assert detail_html =~ "Vulnerability Finding"
    assert detail_html =~ "CVE-2025-68121"
    assert detail_html =~ "crypto/tls: Unexpected session resumption in crypto/tls"
    assert detail_html =~ "Fixed In"
    assert detail_html =~ "golang"
    assert detail_html =~ "v1.24.6"
    assert detail_html =~ "1.24.13"
    assert detail_html =~ "pkg:golang/stdlib@v1.24.6"
    assert detail_html =~ "bitnami/sealed-secrets-controller:0.32.2"
    assert detail_html =~ "agent-k8s-cp3-worker1"
    assert detail_html =~ "controller"
    assert detail_html =~ "ReplicaSet/sealed-secrets-54d6d7dc89"
    assert detail_html =~ "Raw report"
  end

  test "security cards expose scoped drill-down destinations", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/security")
    html = render_async(view, 5_000)

    assert has_element?(
             view,
             "a[href*='in%3Asecurity_findings'][href*='sort%3Atime%3Adesc']",
             "Scanner findings"
           )

    assert has_element?(
             view,
             "a[href*='in%3Ascan_activity'][href*='status%3AFailure']",
             "Failed scans"
           )

    assert has_element?(
             view,
             "a[href*='in%3Adns_activity'][href*='source%3Apowerdns']",
             "DNS blocks"
           )

    refute html =~ "No Trivy vulnerability finding rows are available yet"
    refute html =~ "No active OCSF findings found"
  end

  test "security page renders Falco runtime evidence without using raw event details first", %{conn: conn} do
    event_uuid = insert_falco_detection!()

    {:ok, view, _html} = live(conn, ~p"/security?#{%{detection: event_uuid}}")
    html = render_async(view, 5_000)

    assert html =~ "Runtime Detection Evidence"
    assert html =~ "Terminal shell in container"
    assert html =~ "bash"
    assert html =~ "/bin/bash"
    assert html =~ "demo/demo-nginx"
    assert has_element?(view, "a[href='/events/#{event_uuid}']", "Raw event")
  end

  test "dashboard hub lists bundled security and endpoint inventory dashboards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards")
    html = render_async(view, 5_000)

    assert html =~ "Dashboard &amp; Report Library"
    assert html =~ "Security Findings"
    assert html =~ "Endpoint Inventory"
    assert has_element?(view, "a[href='/dashboards/security-findings']")
    assert has_element?(view, "a[href='/dashboards/endpoint-inventory']")
  end

  test "security package dashboard is differentiated from the tactical work queue", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/security")
    security_html = render_async(view, 5_000)

    assert security_html =~ "Security analytics workbench"
    refute security_html =~ "Trivy Vulnerabilities"
    assert has_element?(view, "a[href='/dashboards/security-findings']", "Security Findings")

    dashboard_js =
      File.read!(Path.expand("../../../assets/js/dashboards/security_findings.js", __DIR__))

    assert dashboard_js =~ "Exposure Posture"
    assert dashboard_js =~ "Open work queue"
    assert dashboard_js =~ "Editable posture panels"
    refute dashboard_js =~ "Trivy Vulnerabilities"
  end

  @tag :web_ng_shared_fixture_db
  test "bundled dashboard routes load the package host with the saved display zone", %{
    conn: conn,
    user: user
  } do
    timezone = user.timezone || "Etc/UTC"

    for route_slug <- ["security-findings", "endpoint-inventory"] do
      {:ok, view, _html} = live(conn, ~p"/dashboards/#{route_slug}")
      html = render_async(view, 5_000)

      assert html =~ "dashboard-package-host"
      assert has_element?(view, "[phx-hook='DashboardWasmHost'][data-host]")

      assert has_element?(
               view,
               "[phx-hook='DashboardWasmHost'][data-timezone='#{timezone}']"
             )

      refute html =~ "Dashboard package unavailable"
      refute html =~ "Dashboard package failed to load"
    end
  end

  test "security dashboard defers but activates source coverage probes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/security-findings")
    _ = render_async(view, 5_000)

    [host_json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-hook='DashboardWasmHost']")
      |> LazyHTML.attribute("data-host")

    stream_token =
      host_json
      |> Jason.decode!()
      |> get_in(["data_provider", "stream_token"])

    assert {:ok, stream} =
             Phoenix.Token.verify(
               ServiceRadarWebNGWeb.Endpoint,
               "dashboard-frame-stream-v1",
               stream_token,
               max_age: 3_600
             )

    assert MapSet.new(stream["active_frame_ids"]) ==
             MapSet.new([
               "vulnerability_findings",
               "trivy_findings_latest",
               "trivy_scan_latest",
               "bumblebee_findings_latest",
               "bumblebee_scan_latest",
               "falco_findings_latest",
               "endpoint_inventory_findings_latest",
               "powerdns_dns_latest"
             ])
  end

  defp insert_trivy_finding!(event_uuid, finding_uuid) do
    observed_at = DateTime.utc_now()
    dumped_event_uuid = Ecto.UUID.dump!(event_uuid)
    dumped_finding_uuid = Ecto.UUID.dump!(finding_uuid)

    Repo.insert_all(
      "trivy_reports",
      [
        %{
          event_uuid: dumped_event_uuid,
          observed_at: observed_at,
          report_kind: "VulnerabilityReport",
          cluster_id: "demo",
          namespace: "sealed-secrets",
          name: "replicaset-sealed-secrets-54d6d7dc89-controller",
          uid: "84e7db6e-633d-4bc4-9bf1-165b02a8a250",
          resource_version: "133476400",
          resource_kind: "ReplicaSet",
          resource_name: "sealed-secrets-54d6d7dc89",
          resource_namespace: "sealed-secrets",
          container_name: "controller",
          severity_id: 5,
          severity_text: "CRITICAL",
          status_id: 2,
          findings_count: 1,
          summary: %{"criticalCount" => 1},
          owner_ref: %{},
          correlation: %{},
          report_metadata: %{},
          report_payload: %{},
          raw_payload: %{}
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "trivy_findings",
      [
        %{
          finding_uuid: dumped_finding_uuid,
          event_uuid: dumped_event_uuid,
          observed_at: observed_at,
          report_kind: "VulnerabilityReport",
          cluster_id: "demo",
          namespace: "sealed-secrets",
          agent_id: "agent-k8s-cp3-worker1",
          device_uid: "sr:trivy-node-1",
          resource_kind: "ReplicaSet",
          resource_name: "sealed-secrets-54d6d7dc89",
          resource_namespace: "sealed-secrets",
          host_ip: "10.42.3.25",
          node_name: "agent-k8s-cp3-worker1",
          container_name: "controller",
          owner_kind: "ReplicaSet",
          owner_name: "sealed-secrets-54d6d7dc89",
          owner_uid: "303d4c99-6b82-4d72-b5af-81fa5f8cead2",
          image_repository: "bitnami/sealed-secrets-controller",
          image_tag: "0.32.2",
          image_digest: "sha256:abc123",
          finding_type: "vulnerability",
          finding_id: "CVE-2025-68121",
          target: "bitnami/sealed-secrets-controller:0.32.2",
          title: "crypto/tls: Unexpected session resumption in crypto/tls",
          severity_text: "CRITICAL",
          severity_id: 5,
          status: "open",
          package_name: "golang",
          package_purl: "pkg:golang/stdlib@v1.24.6",
          installed_version: "v1.24.6",
          fixed_version: "1.24.13, 1.25.7, 1.26.0-rc.3",
          description: "TLS session resumption vulnerability",
          references: ["https://avd.aquasec.com/nvd/cve-2025-68121"],
          raw_finding: %{"vulnerabilityID" => "CVE-2025-68121"},
          fingerprint: "trivy-test-#{event_uuid}-CVE-2025-68121"
        }
      ],
      prefix: "platform"
    )
  end

  defp insert_falco_detection! do
    event_uuid = Ecto.UUID.generate()
    dumped_event_uuid = Ecto.UUID.dump!(event_uuid)

    diagnostics = %{
      "rule" => %{"name" => "Terminal shell in container", "priority" => "High"},
      "host" => %{"name" => "agent-k8s-cp2-worker2"},
      "process" => %{"name" => "bash", "command" => "/bin/bash", "executable" => "/bin/bash"},
      "user" => %{"name" => "root"},
      "container" => %{
        "name" => "demo-nginx",
        "image" => %{"repository" => "nginx", "tag" => "1.25"}
      },
      "kubernetes" => %{"namespace" => "demo", "pod" => "demo-nginx"},
      "file" => %{"path" => "/bin/bash"}
    }

    Repo.insert_all(
      "ocsf_events",
      [
        %{
          id: dumped_event_uuid,
          time: DateTime.utc_now(),
          class_uid: 2004,
          category_uid: 2,
          type_uid: 2_004_001,
          activity_id: 1,
          activity_name: "Detection",
          severity_id: 4,
          severity: "High",
          message: "Falco detected Terminal shell in container",
          status_id: 1,
          status: "Success",
          metadata: %{
            "security_signal" => %{"diagnostics" => diagnostics},
            "service_radar" => %{
              "source_type" => "falco",
              "device_hostname" => "agent-k8s-cp2-worker2"
            }
          },
          observables: [],
          actor: %{},
          device: %{"name" => "agent-k8s-cp2-worker2"},
          src_endpoint: %{},
          dst_endpoint: %{},
          log_provider: "falco",
          unmapped: %{},
          raw_data: Jason.encode!(%{"diagnostics" => diagnostics})
        }
      ],
      prefix: "platform"
    )

    event_uuid
  end

  defmodule SRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query, _opts) when is_binary(query) do
      rows =
        cond do
          String.contains?(query, "source:falco") ->
            [falco_row()]

          String.starts_with?(query, "in:security_findings ") and
              not String.contains?(query, "source:") ->
            [medium_row(), falco_row()]

          true ->
            []
        end

      {:ok, %{"results" => rows, "pagination" => %{}, "error" => nil}}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp falco_row do
      diagnostics = %{
        "rule" => %{"name" => "Terminal shell in container", "priority" => "High"},
        "host" => %{"name" => "agent-k8s-cp2-worker2"},
        "process" => %{"name" => "bash", "command" => "/bin/bash", "executable" => "/bin/bash"},
        "user" => %{"name" => "root"},
        "container" => %{
          "name" => "demo-nginx",
          "image" => %{"repository" => "nginx", "tag" => "1.25"}
        },
        "kubernetes" => %{"namespace" => "demo", "pod" => "demo-nginx"},
        "file" => %{"path" => "/bin/bash"}
      }

      %{
        "id" => "falco-event-1",
        "class_uid" => 2004,
        "severity" => "High",
        "source" => "falco",
        "log_provider" => "falco",
        "event_timestamp" => "2026-06-10T21:01:33Z",
        "short_message" => "Terminal shell in container",
        "message" => "Falco detected Terminal shell in container",
        "metadata" => %{
          "security_signal" => %{"diagnostics" => diagnostics},
          "service_radar" => %{"source_type" => "falco", "device_hostname" => "agent-k8s-cp2-worker2"}
        },
        "raw_data" => %{"diagnostics" => diagnostics}
      }
    end

    defp medium_row do
      %{
        "id" => "medium-event-1",
        "class_uid" => 2004,
        "severity" => "Medium",
        "source" => "falco",
        "log_provider" => "falco",
        "event_timestamp" => "2026-06-10T21:02:33Z",
        "short_message" => "Routine medium finding",
        "message" => "Routine medium finding",
        "metadata" => %{"service_radar" => %{"source_type" => "falco"}}
      }
    end
  end
end
