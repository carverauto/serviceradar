defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.ManagedCertificateLifecycle
  alias ServiceRadar.Edge.ManagedCertificateOperation
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Accounts.Scope

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @private_key "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  @public_key "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  setup %{conn: conn} do
    previous_web_nats_url = Application.get_env(:serviceradar_web_ng, :nats_url)
    previous_core_nats_url = Application.get_env(:serviceradar, :nats_url)
    previous_private_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    previous_public_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_public_key)
    Application.put_env(:serviceradar_web_ng, :nats_url, "tls://serviceradar-nats:4222")
    Application.delete_env(:serviceradar, :nats_url)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, @private_key)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, @public_key)

    on_exit(fn ->
      restore_env(:serviceradar_web_ng, :nats_url, previous_web_nats_url)
      restore_env(:serviceradar, :nats_url, previous_core_nats_url)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous_private_key)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, previous_public_key)
    end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  describe "nats deployment status" do
    test "reads the web-ng NATS URL instead of spinning on provisioning", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Ready"
      assert html =~ "tls://serviceradar-nats:4222"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end

    test "says NATS is not configured when no URL is set", %{conn: conn} do
      Application.delete_env(:serviceradar_web_ng, :nats_url)
      Application.delete_env(:serviceradar, :nats_url)

      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Not Configured"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end
  end

  describe "falcosidekick creation flow" do
    test "shows bundle deployment instructions instead of generic CLI enrollment", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/collectors")

      lv
      |> element("button", "New Collector")
      |> render_click()

      html =
        lv
        |> form("form[phx-submit='create_package']", %{
          "collector_type" => "falcosidekick",
          "site" => "demo",
          "hostname" => "falco-demo",
          "edge_site_id" => ""
        })
        |> render_submit()

      assert html =~ "Collector Created"
      assert html =~ "Step 1: Download and deploy the bundle"
      assert html =~ "Step 2: Run the bundle command"
      assert html =~ "serviceradar-runtime-certs"
      assert html =~ "http://localhost:4002/api/collectors/"
      assert html =~ "./deploy.sh"

      refute html =~ "sudo apt install serviceradar-falcosidekick"
      refute html =~ "/usr/local/bin/srctl enroll --token"
    end
  end

  describe "collector capability gating" do
    test "hides collector creation UI when onboarding is disabled", %{conn: conn} do
      previous_capabilities = Application.get_env(:serviceradar_web_ng, :runtime_capabilities)

      Application.put_env(:serviceradar_web_ng, :runtime_capabilities,
        configured?: true,
        enabled: []
      )

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, :runtime_capabilities, previous_capabilities)
      end)

      {:ok, lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "Collector onboarding is disabled for this deployment."
      refute html =~ "New Collector"
      # The page keeps its own title; the settings navigation must not offer it.
      assert has_element?(lv, "#settings-view-tree")
      refute has_element?(lv, "#settings-view-tree a[href='/admin/collectors']")
    end
  end

  test "managed installation replaces stale bundle state in lists, details and filters", %{
    conn: conn,
    user: user
  } do
    opts = [actor: SystemActor.system(:managed_deployment_status_test)]
    suffix = Ash.UUID.generate()
    host = "example-agent-#{suffix}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: host, name: host}, opts)
    |> Ash.create!(opts)

    site =
      EdgeSite
      |> Ash.Changeset.for_create(:create, %{name: "Example installation", slug: "example-#{suffix}"}, opts)
      |> Ash.create!(opts)

    package = failed_package(site.id, opts)
    legacy = failed_package(nil, opts)

    deployments =
      for {record, type, binding} <- [
            {site, "nats-leaf", %{edge_site_id: site.id}},
            {package, "log-collector", %{collector_id: package.id, edge_site_id: site.id}}
          ] do
        component =
          ManagedComponent
          |> Ash.Changeset.for_create(
            :enroll,
            Map.merge(binding, %{
              component_id: "example-#{type}-#{suffix}",
              component_type: type,
              host_agent_id: host,
              partition_id: "example-partition"
            }),
            opts
          )
          |> Ash.create!(opts)

        operation =
          ManagedCertificateOperation
          |> Ash.Changeset.for_create(
            :begin,
            %{
              component_id: component.component_id,
              generation: component.generation,
              host_agent_id: host,
              partition_id: "example-partition",
              service: type,
              requested_by: "example-operator"
            },
            opts
          )
          |> Ash.create!(opts)

        operation
        |> Ash.Changeset.for_update(
          :progress,
          %{status: :activated, receipt: %{"installed" => true, "activated" => true}},
          opts
        )
        |> Ash.update!(opts)

        {record, component}
      end

    scope = Scope.for_user(user)
    assert_deployment_filter(deployments, "installed", scope)

    assert Ash.get!(CollectorPackage, legacy.id, Keyword.put(opts, :load, :deployment_status)).deployment_status ==
             "failed"

    {:ok, sites, _} = live(conn, ~p"/admin/edge-sites")
    assert has_element?(sites, "#edge-site-#{site.id} td:nth-child(2)", "installed")
    sites |> element("select[name='status']") |> render_change(%{"status" => "installed"})
    assert has_element?(sites, "#edge-site-#{site.id}")

    {:ok, collectors, _} = live(conn, ~p"/admin/collectors")
    assert has_element?(collectors, "#collector-#{package.id} td:nth-child(3)", "installed")
    assert has_element?(collectors, "#collector-#{legacy.id} td:nth-child(3)", "failed")
    refute has_element?(collectors, "#collector-#{package.id} button[phx-click='revoke_package']")
    collectors |> element("select[name='status']") |> render_change(%{"status" => "installed"})
    assert has_element?(collectors, "#collector-#{package.id}")
    refute has_element?(collectors, "#collector-#{legacy.id}")

    {:ok, details, _} = live(conn, ~p"/admin/edge-sites/#{site.id}")
    assert has_element?(details, "a[href='/admin/service-certificates']", "Manage service certificates")
    assert render(details) =~ "It does not confirm that the service is currently connected."

    {:ok, collector_details, _} = live(conn, ~p"/admin/collectors/#{package.id}")
    assert has_element?(collector_details, "#details_modal", "installed")
    refute render(collector_details) =~ "example bundle provisioning failure"

    renewals =
      for {_record, component} <- deployments do
        component.component_id
        |> ManagedCertificateLifecycle.current(opts)
        |> then(fn {:ok, activated} -> activated end)
        |> Ash.Changeset.for_update(:supersede, %{}, opts)
        |> Ash.update!(opts)

        ManagedCertificateOperation
        |> Ash.Changeset.for_create(
          :begin,
          %{
            component_id: component.component_id,
            generation: component.generation,
            host_agent_id: host,
            partition_id: "example-partition",
            service: component.component_type,
            requested_by: "example-operator"
          },
          opts
        )
        |> Ash.create!(opts)
      end

    # A renewal in progress keeps the prior acknowledged installation.
    assert_deployment_filter(deployments, "installed", scope)

    for renewal <- renewals do
      renewal
      |> Ash.Changeset.for_update(:progress, %{status: :failed, error: "prepare_failed"}, opts)
      |> Ash.update!(opts)
    end

    # A failed renewal does not mark a still-installed host as failed.
    assert_deployment_filter(deployments, "installed", scope)

    send(collectors.pid, :refresh_deployments)
    assert has_element?(collectors, "#collector-#{package.id} td:nth-child(3)", "installed")

    {:ok, renewal_details, _} = live(conn, ~p"/admin/edge-sites/#{site.id}")
    assert render(renewal_details) =~ "Certificate renewal: failed"
    assert render(renewal_details) =~ "prepare_failed"

    render_click(collectors, "open_create_modal", %{})
    assert has_element?(collectors, "select[name='edge_site_id'] option[value='#{site.id}']")

    revoked =
      for {record, component} <- deployments do
        blocked = component |> Ash.Changeset.for_update(:block, %{}, opts) |> Ash.update!(opts)
        {record, blocked}
      end

    assert_deployment_filter(revoked, "revoked", scope)
    send(collectors.pid, :refresh_deployments)
    refute has_element?(collectors, "#collector-#{package.id}")
    collectors |> element("select[name='status']") |> render_change(%{"status" => "revoked"})
    assert has_element?(collectors, "#collector-#{package.id} td:nth-child(3)", "revoked")

    for {_record, component} <- revoked do
      component |> Ash.Changeset.for_update(:reenroll, %{}, opts) |> Ash.update!(opts)
    end

    # The old activated operation must not certify the new enrollment generation.
    assert_deployment_filter(deployments, "pending", scope)
  end

  defp failed_package(site_id, opts) do
    CollectorPackage
    |> Ash.Changeset.for_create(:create, %{collector_type: :flowgger, edge_site_id: site_id}, opts)
    |> Ash.create!(opts)
    |> Ash.Changeset.for_update(:fail, %{error_message: "example bundle provisioning failure"}, opts)
    |> Ash.update!(opts)
  end

  defp assert_deployment_filter(deployments, expected, scope) do
    for {record, _component} <- deployments do
      id = record.id

      query =
        record.__struct__
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.load(:deployment_status)
        |> Ash.Query.filter(id == ^id and deployment_status == ^expected)

      assert [%{deployment_status: ^expected}] = Ash.read!(query, scope: scope)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
