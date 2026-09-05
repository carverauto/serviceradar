defmodule ServiceRadarWebNGWeb.Admin.PluginPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import ServiceRadarWebNG.AshTestHelpers,
    only: [
      actor_for_user: 1,
      admin_user_fixture: 0,
      gateway_fixture: 1,
      agent_fixture: 2,
      system_actor: 0
    ]

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  require Ash.Query

  @repo_url "https://github.com/carverauto/serviceradar"
  @external_repo_url "https://github.com/carverauto/serviceradar-plugin-example-inventory"
  @per_plugin_repo_url "https://github.com/carverauto/serviceradar-plugin-per-plugin-tags"
  @manifest_yaml """
  id: live-first-party-plugin
  name: Live First-party Plugin
  version: 2.0.0
  entrypoint: run_check
  runtime: wasi-preview1
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - get_config
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  """
  @manifest %{
    "id" => "live-first-party-plugin",
    "name" => "Live First-party Plugin",
    "version" => "2.0.0",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config"],
    "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
  }
  @wasm "live first-party wasm payload"

  defmodule GitHubReleaseClient do
    @moduledoc false

    alias ServiceRadarWebNGWeb.Admin.PluginPackageLiveTest

    def get(url, _opts) do
      cond do
        String.contains?(
          url,
          "api.github.com/repos/carverauto/serviceradar-plugin-example-inventory/releases?per_page="
        ) ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [PluginPackageLiveTest.external_release()]
           }}

        String.contains?(
          url,
          "api.github.com/repos/carverauto/serviceradar-plugin-example-inventory/releases/tags/v2.0.0"
        ) ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.external_release()}}

        String.contains?(
          url,
          "api.github.com/repos/carverauto/serviceradar-plugin-per-plugin-tags/releases?per_page="
        ) ->
          {:ok,
           %Req.Response{
             status: 200,
             body: PluginPackageLiveTest.per_plugin_releases()
           }}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [PluginPackageLiveTest.release(), PluginPackageLiveTest.old_release()]
           }}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v2.0.0") ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.release()}}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.0.0") ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.old_release()}}

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          body =
            cond do
              String.contains?(url, "serviceradar-plugin-example-inventory") ->
                PluginPackageLiveTest.external_index()

              String.contains?(url, "/alpha-sensor-v0.1.0/") ->
                PluginPackageLiveTest.per_plugin_index("alpha-sensor", "Alpha Sensor", "0.1.0")

              String.contains?(url, "/beta-sensor-v0.2.0/") ->
                PluginPackageLiveTest.per_plugin_index("beta-sensor", "Beta Sensor", "0.2.0")

              String.contains?(url, "/v1.0.0/") ->
                PluginPackageLiveTest.old_index()

              true ->
                Application.get_env(
                  :serviceradar_web_ng,
                  :plugin_live_test_index,
                  PluginPackageLiveTest.index()
                )
            end

          {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}

        String.ends_with?(url, "/live-first-party-plugin.zip") ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.bundle()}}

        String.ends_with?(url, "/live-first-party-plugin.upload-signature.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(PluginPackageLiveTest.upload_signature())
           }}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup_all do
    original_join_process_registry =
      Application.get_env(:serviceradar_core, :join_process_registry)

    Application.put_env(:serviceradar_core, :join_process_registry, true)
    {:ok, _apps} = Application.ensure_all_started(:horde)

    if is_nil(Process.whereis(ProcessRegistry.registry_name())) do
      Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
    end

    on_exit(fn ->
      if is_nil(original_join_process_registry) do
        Application.delete_env(:serviceradar_core, :join_process_registry)
      else
        Application.put_env(
          :serviceradar_core,
          :join_process_registry,
          original_join_process_registry
        )
      end
    end)

    :ok
  end

  setup %{conn: conn} do
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)

    original_client =
      Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)

    original_import_config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import)
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_artifact_upload = Application.get_env(:serviceradar_web_ng, :plugin_artifact_upload)
    original_bundle = Application.get_env(:serviceradar_web_ng, :plugin_live_test_bundle)
    original_signature = Application.get_env(:serviceradar_web_ng, :plugin_live_test_signature)
    original_index = Application.get_env(:serviceradar_web_ng, :plugin_live_test_index)

    store_name = :"sr_plugin_live_test_#{System.unique_integer([:positive])}"
    {:ok, _store} = ServiceRadarWebNG.PluginStorageTestClient.start_link(store_name)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"live-test" => Base.encode64(public_key)}
    )

    Application.put_env(
      :serviceradar_web_ng,
      :first_party_plugin_import_http_client,
      GitHubReleaseClient
    )

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      repo_url: @repo_url,
      index_asset_name: "serviceradar-wasm-plugin-index.json",
      auto_sync_enabled: false,
      sync_release_limit: 10
    )

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :jetstream,
      jetstream_client: ServiceRadarWebNG.PluginStorageTestClient,
      test_store: store_name,
      signing_secret: "test-secret"
    )

    # First-party imports mirror artifacts to datasvc in production. This focused
    # LiveView suite uses an in-memory plugin storage backend, so make the
    # cross-service mirror explicit and deterministic instead of attempting a
    # direct gRPC connection when datasvc is intentionally absent.
    Application.put_env(:serviceradar_web_ng, :plugin_artifact_upload, fn _metadata, _payload, _opts ->
      {:ok, :test_mirror}
    end)

    Process.put(:live_first_party_private_key, private_key)
    Process.put(:live_first_party_bundle, nil)
    Process.put(:live_first_party_signature, nil)
    Application.put_env(:serviceradar_web_ng, :plugin_live_test_bundle, bundle())
    Application.put_env(:serviceradar_web_ng, :plugin_live_test_signature, upload_signature())

    user = admin_user_fixture()

    on_exit(fn ->
      restore_env(:plugin_verification, original_policy)
      restore_env(:first_party_plugin_import_http_client, original_client)
      restore_env(:first_party_plugin_import, original_import_config)
      restore_env(:plugin_storage, original_storage)
      restore_env(:plugin_artifact_upload, original_artifact_upload)
      restore_env(:plugin_live_test_bundle, original_bundle)
      restore_env(:plugin_live_test_signature, original_signature)
      restore_env(:plugin_live_test_index, original_index)
    end)

    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  test "syncs the first-party plugin catalog", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/admin/plugins")

    assert html =~ "Plugin catalog"
    refute html =~ "Live First-party Plugin"

    lv
    |> element("button[phx-click='sync_first_party_catalog']")
    |> render_click()

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Live First-party Plugin"
    assert html =~ "live-first-party-plugin"
    assert html =~ "import-ready"
  end

  test "loads and imports a signed catalog from a trusted external repository", %{
    conn: conn,
    actor: actor
  } do
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    html =
      lv
      |> form("#select-first-party-repository-form", %{
        "catalog_repository" => %{"repo_url" => @external_repo_url}
      })
      |> render_submit()

    assert html =~ @external_repo_url
    assert html =~ "Live First-party Plugin"

    lv
    |> element("button[phx-click='import_first_party_plugin'][phx-value-plugin-id='live-first-party-plugin']")
    |> render_click()

    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)
    assert package.source_type == :first_party
    assert package.source_repo_url == @external_repo_url
    assert package.source_release_tag == "v2.0.0"
  end

  test "a repository tagging one release per plugin shows all of its plugins", %{conn: conn} do
    # Every tag here is per-plugin (`alpha-sensor-v0.1.0`), so none matches the
    # first-party `vX.Y.Z` shape. Filtering the release options by that shape
    # discarded them all, the selector fell back to an imported package's tag
    # from a different repository, and the catalog then filtered its own entries
    # against that foreign tag and reported finding nothing.
    repository = create_repository!("per-plugin", @per_plugin_repo_url)

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    lv
    |> form("#select-first-party-repository-form", %{"repository_id" => repository.id})
    |> render_change()

    html = lv |> element("#plugin-catalog") |> render()

    refute html =~ "no import-ready plugin entries were found"
    assert html =~ "Alpha Sensor"
    assert html =~ "Beta Sensor"
    assert html =~ "All releases"
  end

  test "a repository's catalog does not show packages imported from another repository", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])
    repository = create_repository!("per-plugin", @per_plugin_repo_url)

    # Imported from the built-in ServiceRadar repository, not from the
    # per-plugin one being browsed. With "All releases" selected, a release-tag
    # comparison alone no longer excludes it -- only its origin does.
    create_catalog_package!(
      system_actor(),
      "v2.0.0",
      "foreign-imported-plugin-#{unique}",
      "2.0.0",
      @repo_url
    )

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    lv
    |> form("#select-first-party-repository-form", %{"repository_id" => repository.id})
    |> render_change()

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Alpha Sensor"
    refute html =~ "foreign-imported-plugin-#{unique}"
  end

  test "plugin catalog defaults to latest official release and can select older releases", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])
    create_catalog_package!(system_actor(), "v2.0.0", "live-imported-plugin-#{unique}", "2.0.0")

    create_catalog_package!(
      system_actor(),
      "sha-#{unique}",
      "non-release-plugin-#{unique}",
      "2.0.0"
    )

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    lv
    |> element("button[phx-click='sync_first_party_catalog']")
    |> render_click()

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Showing 1 first-party plugin entry(s) from release v2.0.0"
    assert html =~ "Live First-party Plugin"
    assert html =~ "Live live-imported-plugin-#{unique}"
    assert html =~ "v2.0.0"
    refute html =~ "Old First-party Plugin"
    refute html =~ "sha-#{unique}"
    refute html =~ "non-release-plugin-#{unique}"

    lv
    |> form("form[phx-change='select_first_party_release']", %{release_tag: "v1.0.0"})
    |> render_change()

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Old First-party Plugin"
    assert html =~ "v1.0.0"
    refute html =~ "Live First-party Plugin"
    refute html =~ "Live live-imported-plugin-#{unique}"
  end

  test "keeps imported packages visible after the connected catalog load", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])

    package =
      create_catalog_package!(
        actor,
        "v1.0.0",
        "connected-mount-import-#{unique}",
        "1.0.0"
      )

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    assert has_element?(
             lv,
             "#select-plugin-release-form option[value='v2.0.0'][selected]"
           )

    assert has_element?(
             lv,
             "#imported-plugin-packages #imported-plugin-package-#{package.id}"
           )
  end

  test "filtering imported packages does not change catalog import state", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_catalog_package!(actor, "v2.0.0", "live-first-party-plugin", "2.0.0")

    package_path = ~p"/admin/plugins/#{package.id}"
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    assert has_element?(
             lv,
             "#plugin-catalog a[href='#{package_path}']"
           )

    refute has_element?(
             lv,
             "#plugin-catalog button[phx-click='import_first_party_plugin'][phx-value-plugin-id='live-first-party-plugin']"
           )

    lv
    |> form("#filter-imported-plugin-packages", %{
      "status" => "approved",
      "source_type" => ""
    })
    |> render_change()

    refute has_element?(
             lv,
             "#imported-plugin-packages #imported-plugin-package-#{package.id}"
           )

    assert has_element?(
             lv,
             "#plugin-catalog a[href='#{package_path}']"
           )

    refute has_element?(
             lv,
             "#plugin-catalog button[phx-click='import_first_party_plugin'][phx-value-plugin-id='live-first-party-plugin']"
           )
  end

  test "first-party repository plugins are paginated ten at a time", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :plugin_live_test_index, index_with_plugins(12))

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    html =
      lv
      |> element("button[phx-click='sync_first_party_catalog']")
      |> render_click()

    assert html =~ "Showing 1-10 of 12"
    assert html =~ "Catalog Plugin 01"
    assert html =~ "Catalog Plugin 10"
    refute html =~ "Catalog Plugin 11"
    refute html =~ "Catalog Plugin 12"

    html =
      lv
      |> element("#first-party-catalog-next-page")
      |> render_click()

    assert html =~ "Showing 11-12 of 12"
    assert html =~ "Catalog Plugin 11"
    assert html =~ "Catalog Plugin 12"
    refute html =~ "Catalog Plugin 01"
  end

  test "catalog and imported package panels paginate independently", %{conn: conn, actor: actor} do
    unique = System.unique_integer([:positive])

    for index <- 1..12 do
      suffix = index |> Integer.to_string() |> String.pad_leading(2, "0")

      create_catalog_package!(
        actor,
        "v9.0.0",
        "installed-plugin-#{unique}-#{suffix}",
        "1.0.#{index}"
      )
    end

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    imported_html = lv |> element("#imported-plugin-packages") |> render()

    assert imported_html =~ "Showing 1-10 of 12"
    assert imported_html =~ "Live installed-plugin-#{unique}-12"
    refute imported_html =~ "Live installed-plugin-#{unique}-01"

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Showing 1-10 of 12"
    assert html =~ "Live installed-plugin-#{unique}-01"
    assert html =~ "Live installed-plugin-#{unique}-10"
    refute html =~ "Live installed-plugin-#{unique}-11"
    refute html =~ "Live installed-plugin-#{unique}-12"

    lv
    |> element("#first-party-catalog-next-page")
    |> render_click()

    html = lv |> element("#plugin-catalog") |> render()

    assert html =~ "Showing 11-12 of 12"
    assert html =~ "Live installed-plugin-#{unique}-11"
    assert html =~ "Live installed-plugin-#{unique}-12"
    refute html =~ "Live installed-plugin-#{unique}-01"

    lv
    |> element("#plugin-packages-next-page")
    |> render_click()

    imported_html = lv |> element("#imported-plugin-packages") |> render()

    assert imported_html =~ "Showing 11-12 of 12"
    assert imported_html =~ "Live installed-plugin-#{unique}-01"
    refute imported_html =~ "Live installed-plugin-#{unique}-12"
  end

  test "imports a first-party plugin from the catalog", %{conn: conn, actor: actor} do
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    lv
    |> element("button[phx-click='sync_first_party_catalog']")
    |> render_click()

    lv
    |> element("button[phx-click='import_first_party_plugin'][phx-value-plugin-id='live-first-party-plugin']")
    |> render_click()

    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)
    assert package.source_type == :first_party
    assert package.source_release_tag == "v2.0.0"
    assert package.source_bundle_digest == Storage.sha256(bundle())
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  test "Import All reflects state, shows progress, and is idempotent", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    html =
      lv
      |> element("button[phx-click='sync_first_party_catalog']")
      |> render_click()

    # Importable work is visible before acting.
    assert html =~ "Import All (1)"

    # The click itself flips the button into an in-progress state while the
    # async import runs.
    html =
      lv
      |> element("button[phx-click='import_first_party_catalog']")
      |> render_click()

    assert html =~ "Importing"

    # Completion reports a summary and the action now reflects the imported
    # state (relabeled + disabled, nothing importable).
    html = render_async(lv, 5_000)
    assert html =~ "1 imported, 0 skipped"
    assert html =~ "All 1 imported"
    assert has_element?(lv, "button[phx-click='import_first_party_catalog'][disabled]")

    assert [package] =
             Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: system_actor())

    # Forcing the event again (bypassing the disabled button) is idempotent
    # server-side: the entry is skipped, nothing is re-imported or duplicated.
    render_click(lv, "import_first_party_catalog", %{})
    html = render_async(lv, 5_000)

    assert html =~ "0 imported, 1 skipped (already imported)"

    assert [%{id: same_id}] =
             Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: system_actor())

    assert same_id == package.id
  end

  test "plugin assignment agent selector excludes stale agents", %{conn: conn, actor: actor} do
    gateway = gateway_fixture(%{id: "plugin-agent-gw", component_id: "plugin-agent-component"})
    agent_fixture(gateway, %{uid: "agent-active-plugin", name: "Agent Active Plugin"})

    stale_agent = agent_fixture(gateway, %{uid: "agent-stale-plugin", name: "Agent Stale Plugin"})

    stale_agent
    |> Ash.Changeset.for_update(:update, %{}, actor: system_actor())
    |> Ash.Changeset.force_change_attribute(:status, :unavailable)
    |> Ash.Changeset.force_change_attribute(
      :last_seen_time,
      DateTime.add(DateTime.utc_now(), -3_600, :second)
    )
    |> Ash.update!()

    assert {:ok, %{failed: []}} =
             Packages.sync_first_party_plugins(
               actor: actor,
               repo_url: @repo_url,
               release_tag: "v2.0.0",
               limit: 10
             )

    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)

    {:ok, _lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "Agent Active Plugin"
    assert html =~ "agent-active-plugin"
    refute html =~ "Agent Stale Plugin"
    refute html =~ "agent-stale-plugin"
  end

  test "shows an authenticated partition preview without exposing a partition field", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{id: "plugin-preview-gw", component_id: "plugin-preview-component"})

    agent = agent_fixture(gateway, %{uid: "agent-preview-plugin", name: "Agent Preview Plugin"})
    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-preview-plugin", "1.0.0")
    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "Assign to Agent"
    refute html =~ "assignment[partition_id]"
    refute html =~ "name=\"partition_id\""

    html =
      lv
      |> form("form[phx-submit='create_assignment']", %{
        "assignment" => %{"agent_uid" => agent.uid}
      })
      |> render_change()

    assert html =~ "Authenticated partition: #{partition_id}"
    assert html =~ "current live mTLS control session"
    refute html =~ "assignment[partition_id]"
    refute html =~ "name=\"partition_id\""
  end

  test "does not enable assign until the selected agent has a live control session", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-offline-preview-gw",
        component_id: "plugin-offline-preview-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-offline-preview-plugin",
        name: "Agent Offline Preview Plugin"
      })

    package = create_approved_package_version!(actor, "live-offline-preview-plugin", "1.0.0")
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins/#{package.id}")

    html =
      lv
      |> form("form[phx-submit='create_assignment']", %{
        "assignment" => %{"agent_uid" => agent.uid}
      })
      |> render_change()

    assert html =~ "Authenticated partition: unavailable"
    assert html =~ "No live authenticated control session"
    assert html =~ ~s(disabled)
  end

  test "hides quarantined manual history from the normal assignment workflow", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-manual-gw",
        component_id: "plugin-legacy-manual-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-manual-plugin",
        name: "Agent Legacy Manual Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-legacy-manual-plugin", "1.0.0")
    assignment = create_assignment!(actor, agent.uid, package.id)
    quarantine_assignment!(assignment.id)

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    refute html =~ "Unbound legacy manual assignment"
    refute html =~ "Legacy recovery candidates"
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute has_element?(lv, "#request-manual-reapproval-#{assignment.id}")
    assert legacy_unbound_row?(assignment.id)
  end

  test "keeps incompatible quarantined history hidden and disabled", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-schema-gw",
        component_id: "plugin-legacy-schema-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-schema-plugin",
        name: "Agent Legacy Schema Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-legacy-schema-plugin", "1.0.0")
    assignment = create_assignment!(actor, agent.uid, package.id)
    quarantine_assignment!(assignment.id)

    current_schema = %{
      "type" => "object",
      "additionalProperties" => true,
      "required" => ["now_required"],
      "properties" => %{"now_required" => %{"type" => "string"}}
    }

    package
    |> Ash.Changeset.for_update(:update, %{config_schema: current_schema}, actor: actor)
    |> Ash.update!(actor: actor)

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    refute html =~ "Inactive legacy record"
    refute html =~ "Its old configuration cannot be migrated safely."
    refute has_element?(lv, "#request-manual-reapproval-#{assignment.id}")
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute html =~ "Legacy recovery candidates"
    assert legacy_unbound_row?(assignment.id)
  end

  test "allows a fresh assignment without mutating quarantined history", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-upsert-gw",
        component_id: "plugin-legacy-upsert-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-upsert-plugin",
        name: "Agent Legacy Upsert Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-legacy-upsert-plugin", "1.0.0")
    assignment = create_assignment!(actor, agent.uid, package.id)
    quarantine_assignment!(assignment.id)

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins/#{package.id}")

    html =
      lv
      |> form("form[phx-submit='create_assignment']", %{
        "assignment" => %{
          "agent_uid" => agent.uid,
          "interval_seconds" => "60",
          "timeout_seconds" => "10",
          "params" => "{}",
          "permissions_override" => "{}",
          "resources_override" => "{}"
        }
      })
      |> render_submit()

    assert html =~ "Assignment created"
    refute html =~ "Use its recovery action instead of updating it."
    assert legacy_unbound_row?(assignment.id)

    current =
      %{"agent_uid" => agent.uid, "plugin_package_id" => package.id}
      |> Assignments.list()
      |> Enum.find(fn candidate -> candidate.id != assignment.id end)

    assert current.enabled
    assert current.partition_id == partition_id
  end

  test "keeps offline quarantined history out of the operator workflow", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-offline-gw",
        component_id: "plugin-legacy-offline-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-offline-plugin",
        name: "Agent Legacy Offline Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    package = create_approved_package_version!(actor, "live-legacy-offline-plugin", "1.0.0")
    assignment = create_assignment!(actor, agent.uid, package.id)
    quarantine_assignment!(assignment.id)
    unregister_control_session!(partition_id, agent.uid)

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    refute html =~ "Legacy record waiting for agent connection"
    refute has_element?(lv, "#request-manual-reapproval-#{assignment.id}")
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute html =~ "Legacy recovery candidates"
    assert legacy_unbound_row?(assignment.id)
  end

  test "hides policy history while authoritative reconcilers restore desired state", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-policy-gw",
        component_id: "plugin-legacy-policy-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-policy-plugin",
        name: "Agent Legacy Policy Plugin"
      })

    partition_id = "tonka01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-legacy-policy-plugin", "1.0.0")
    policy = create_plugin_target_policy!(actor, package.id)

    assignment =
      create_assignment!(actor, agent.uid, package.id, source: :policy, policy_id: policy.id)

    quarantine_assignment!(assignment.id)

    user = grant_permissions(admin_user_fixture(), ["plugins.view", "settings.plugins.manage"])

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/admin/plugins/#{package.id}")
    html = render(lv)

    refute html =~ "Unbound legacy policy assignment"
    refute html =~ "Legacy recovery candidates"
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute has_element?(lv, "#request-policy-reconciliation-#{assignment.id}")
    assert legacy_unbound_row?(assignment.id)
  end

  test "keeps unsupported historical policy owners hidden and auditable", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-unsupported-policy-gw",
        component_id: "plugin-legacy-unsupported-policy-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-unsupported-policy-plugin",
        name: "Agent Legacy Unsupported Policy Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package =
      create_approved_package_version!(actor, "live-legacy-unsupported-policy-plugin", "1.0.0")

    assignment =
      create_assignment!(actor, agent.uid, package.id,
        source: :policy,
        policy_id: "ansible:awx-inventory-sync"
      )

    quarantine_assignment!(assignment.id)

    user = grant_permissions(admin_user_fixture(), ["plugins.view", "settings.plugins.manage"])

    {:ok, lv, html} = live(log_in_user(conn, user), ~p"/admin/plugins/#{package.id}")

    refute html =~ "Unbound legacy policy assignment"
    refute html =~ "ansible:awx-inventory-sync"
    refute html =~ "Legacy recovery candidates"
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute has_element?(lv, "#request-policy-reconciliation-#{assignment.id}")
    assert legacy_unbound_row?(assignment.id)
  end

  test "does not expose credential-rule history as an operator recovery action",
       %{
         conn: conn,
         actor: actor
       } do
    gateway =
      gateway_fixture(%{
        id: "plugin-legacy-credential-gw",
        component_id: "plugin-legacy-credential-component"
      })

    agent =
      agent_fixture(gateway, %{
        uid: "agent-legacy-credential-plugin",
        name: "Agent Legacy Credential Plugin"
      })

    partition_id = "farm01"
    register_control_session!(agent.uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent.uid, node()})
    end)

    package = create_approved_package_version!(actor, "live-legacy-credential-plugin", "1.0.0")

    assignment =
      create_assignment!(actor, agent.uid, package.id,
        source: :policy,
        policy_id: "network-credential-rule:#{Ash.UUID.generate()}:inventory_enrichment"
      )

    quarantine_assignment!(assignment.id)

    user = grant_permissions(admin_user_fixture(), ["plugins.view", "settings.plugins.manage"])

    {:ok, lv, html} = live(log_in_user(conn, user), ~p"/admin/plugins/#{package.id}")

    refute html =~ "Credential permission required"
    refute html =~ "Legacy recovery candidates"
    refute has_element?(lv, "#assignment-#{assignment.id}")
    refute has_element?(lv, "#request-policy-reconciliation-#{assignment.id}")
    assert legacy_unbound_row?(assignment.id)
  end

  test "removes an assignment without crashing when delete returns success", %{
    conn: conn,
    actor: actor
  } do
    gateway = gateway_fixture(%{id: "plugin-delete-gw", component_id: "plugin-delete-component"})
    agent = agent_fixture(gateway, %{uid: "agent-delete-plugin", name: "Agent Delete Plugin"})
    package = create_approved_package_version!(actor, "live-delete-plugin", "1.0.0")
    assignment = create_assignment!(actor, agent.uid, package.id)

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "Agent Delete Plugin"

    html =
      lv
      |> element("button[phx-click='delete_assignment'][phx-value-id='#{assignment.id}']")
      |> render_click()

    assert html =~ "Assignment removed"
    assert {:error, :not_found} = Assignments.get(assignment.id)
  end

  test "shows and runs latest-version assignment upgrade", %{conn: conn, actor: actor} do
    gateway =
      gateway_fixture(%{id: "plugin-upgrade-gw", component_id: "plugin-upgrade-component"})

    agent = agent_fixture(gateway, %{uid: "agent-upgrade-plugin", name: "Agent Upgrade Plugin"})
    plugin_id = "live-upgrade-plugin-#{System.unique_integer([:positive])}"
    old_package = create_approved_package_version!(actor, plugin_id, "1.0.0")
    new_package = create_approved_package_version!(actor, plugin_id, "1.1.0")
    assignment = create_assignment!(actor, agent.uid, old_package.id)

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins/#{new_package.id}")

    assert has_element?(
             lv,
             "#assignment-version-#{assignment.id}",
             "version 1.0.0 -> newer 1.1.0"
           )

    assert has_element?(
             lv,
             "#upgrade-assignment-#{assignment.id}[phx-value-target-package-id='#{new_package.id}']"
           )

    html =
      lv
      |> element("#upgrade-assignment-#{assignment.id}")
      |> render_click()

    assert html =~ "Assignment upgraded"
    assert upgraded_assignment!(actor, assignment.id).plugin_package_id == new_package.id
  end

  test "does not present an older approved version as the latest upgrade", %{
    conn: conn,
    actor: actor
  } do
    gateway =
      gateway_fixture(%{id: "plugin-current-gw", component_id: "plugin-current-component"})

    agent = agent_fixture(gateway, %{uid: "agent-current-plugin", name: "Agent Current Plugin"})
    plugin_id = "live-current-plugin-#{System.unique_integer([:positive])}"
    old_package = create_approved_package_version!(actor, plugin_id, "1.0.0")
    current_package = create_approved_package_version!(actor, plugin_id, "1.1.0")
    assignment = create_assignment!(actor, agent.uid, current_package.id)

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins/#{current_package.id}")

    assert has_element?(
             lv,
             "#assignment-version-#{assignment.id}",
             "version 1.1.0 · latest approved"
           )

    refute has_element?(lv, "#upgrade-assignment-#{assignment.id}")

    assert has_element?(
             lv,
             "#assignment-version-select-#{assignment.id} option[value='#{old_package.id}']",
             "1.0.0 (rollback)"
           )

    assert has_element?(
             lv,
             "#assignment-version-select-#{assignment.id} option[value='']",
             "Change version"
           )
  end

  test "upgrades an assignment to a selected approved version", %{conn: conn, actor: actor} do
    gateway =
      gateway_fixture(%{id: "plugin-version-gw", component_id: "plugin-version-component"})

    agent = agent_fixture(gateway, %{uid: "agent-version-plugin", name: "Agent Version Plugin"})
    plugin_id = "live-version-plugin-#{System.unique_integer([:positive])}"
    old_package = create_approved_package_version!(actor, plugin_id, "1.0.0")
    middle_package = create_approved_package_version!(actor, plugin_id, "1.1.0")
    latest_package = create_approved_package_version!(actor, plugin_id, "1.2.0")
    assignment = create_assignment!(actor, agent.uid, old_package.id)

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{latest_package.id}")

    assert html =~ "1.1.0"
    assert html =~ "1.2.0"

    html =
      lv
      |> form("form[phx-submit='upgrade_assignment'][phx-value-id='#{assignment.id}']", %{
        "assignment_upgrade" => %{"target_package_id" => middle_package.id}
      })
      |> render_submit()

    assert html =~ "Assignment upgraded"
    assert upgraded_assignment!(actor, assignment.id).plugin_package_id == middle_package.id
  end

  test "policy-owned assignments show policy messaging instead of upgrade controls", %{
    conn: conn,
    actor: actor
  } do
    gateway = gateway_fixture(%{id: "plugin-policy-gw", component_id: "plugin-policy-component"})
    agent = agent_fixture(gateway, %{uid: "agent-policy-plugin", name: "Agent Policy Plugin"})
    plugin_id = "live-policy-plugin-#{System.unique_integer([:positive])}"
    old_package = create_approved_package_version!(actor, plugin_id, "1.0.0")
    new_package = create_approved_package_version!(actor, plugin_id, "1.1.0")
    create_assignment!(actor, agent.uid, old_package.id, source: :policy)

    {:ok, _lv, html} = live(conn, ~p"/admin/plugins/#{new_package.id}")

    assert html =~ "managed by policy"
    refute html =~ "phx-value-target-package-id=\"#{new_package.id}\""
  end

  test "stale duplicate-create failures show upgrade guidance", %{conn: conn, actor: actor} do
    gateway =
      gateway_fixture(%{id: "plugin-duplicate-gw", component_id: "plugin-duplicate-component"})

    agent =
      agent_fixture(gateway, %{uid: "agent-duplicate-plugin", name: "Agent Duplicate Plugin"})

    package = create_approved_package_version!(actor, "live-duplicate-plugin", "1.0.0")

    {:ok, lv, _html} = live(conn, ~p"/admin/plugins/#{package.id}")

    _assignment = create_assignment!(actor, agent.uid, package.id)

    html =
      lv
      |> form("form[phx-submit='create_assignment']", %{
        "assignment" => %{
          "agent_uid" => agent.uid,
          "interval_seconds" => "60",
          "timeout_seconds" => "10",
          "params" => "{}",
          "permissions_override" => "{}",
          "resources_override" => "{}"
        }
      })
      |> render_submit()

    assert html =~ "already has this plugin enabled"
    assert html =~ "upgrade or version selector"
  end

  test "does not offer manual assignment for producer-schedule plugins", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_approved_package_version!(actor, "live-schedule-defaults-plugin", "1.0.0",
        producer_schedules: [
          %{
            "schedule_id" => "opentext-nom.inventory.refresh",
            "default_cadence_seconds" => 86_400,
            "min_cadence_seconds" => 3_600,
            "max_cadence_seconds" => 2_592_000,
            "timeout_seconds" => 900
          }
        ]
      )

    {:ok, lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "Do not assign this plugin here"
    assert html =~ "Settings → Networks → Credentials"
    refute html =~ ~s(name="assignment[interval_seconds]")
    refute has_element?(lv, "form[phx-submit='create_assignment']")

    html =
      render_click(lv, "create_assignment", %{
        "assignment" => %{
          "agent_uid" => "agent-ignored",
          "interval_seconds" => "86400",
          "timeout_seconds" => "900"
        }
      })

    assert html =~ "assigned from a credential rule"
  end

  test "shows first-party package provenance", %{conn: conn, actor: actor} do
    assert {:ok, %{failed: []}} =
             Packages.sync_first_party_plugins(
               actor: actor,
               repo_url: @repo_url,
               release_tag: "v2.0.0",
               limit: 10
             )

    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)

    {:ok, _lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "First-party Provenance"
    assert html =~ "v2.0.0"

    assert html =~
             "registry.carverauto.dev/serviceradar/wasm-plugin-live-first-party-plugin:v2.0.0"
  end

  def release do
    %{
      "tag_name" => "v2.0.0",
      "name" => "ServiceRadar v2.0.0",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v2.0.0",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v2.0.0/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def old_release do
    %{
      "tag_name" => "v1.0.0",
      "name" => "ServiceRadar v1.0.0",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.0.0",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.0.0/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def external_release do
    %{
      "tag_name" => "v2.0.0",
      "name" => "Example inventory plugin v2.0.0",
      "html_url" => "https://github.com/carverauto/serviceradar-plugin-example-inventory/releases/tag/v2.0.0",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar-plugin-example-inventory/releases/download/v2.0.0/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "live-first-party-plugin",
          "name" => "Live First-party Plugin",
          "version" => "2.0.0",
          "bundle_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v2.0.0/live-first-party-plugin.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v2.0.0/live-first-party-plugin.upload-signature.json",
          "bundle_digest" => Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-live-first-party-plugin:v2.0.0"
        }
      ]
    }
  end

  def old_index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "old-first-party-plugin",
          "name" => "Old First-party Plugin",
          "version" => "1.0.0",
          "bundle_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.0.0/old-first-party-plugin.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.0.0/old-first-party-plugin.upload-signature.json",
          "bundle_digest" => Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-old-first-party-plugin:v1.0.0"
        }
      ]
    }
  end

  # A repository that publishes one release per plugin, which is the documented
  # third-party pattern: the tag names the plugin, so it never matches the
  # first-party `vX.Y.Z` shape.
  def per_plugin_releases do
    [
      per_plugin_release("alpha-sensor", "0.1.0"),
      per_plugin_release("beta-sensor", "0.2.0")
    ]
  end

  def per_plugin_release(plugin_id, version) do
    tag = "#{plugin_id}-v#{version}"

    %{
      "tag_name" => tag,
      "name" => "#{plugin_id} #{version}",
      "html_url" => "https://github.com/carverauto/serviceradar-plugin-per-plugin-tags/releases/tag/#{tag}",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar-plugin-per-plugin-tags/releases/download/#{tag}/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def per_plugin_index(plugin_id, name, version) do
    tag = "#{plugin_id}-v#{version}"

    %{
      "schema_version" => 1,
      "release_tag" => tag,
      "plugins" => [
        %{
          "plugin_id" => plugin_id,
          "name" => name,
          "version" => version,
          "bundle_url" =>
            "https://github.com/carverauto/serviceradar-plugin-per-plugin-tags/releases/download/#{tag}/#{plugin_id}.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar-plugin-per-plugin-tags/releases/download/#{tag}/#{plugin_id}.upload-signature.json",
          "bundle_digest" => Storage.sha256(bundle())
        }
      ]
    }
  end

  def external_index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "live-first-party-plugin",
          "name" => "Live First-party Plugin",
          "version" => "2.0.0",
          "bundle_url" =>
            "https://github.com/carverauto/serviceradar-plugin-example-inventory/releases/download/v2.0.0/live-first-party-plugin.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar-plugin-example-inventory/releases/download/v2.0.0/live-first-party-plugin.upload-signature.json",
          "bundle_digest" => Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-live-first-party-plugin:v2.0.0"
        }
      ]
    }
  end

  def index_with_plugins(count) do
    %{
      "schema_version" => 1,
      "plugins" =>
        Enum.map(1..count, fn index ->
          suffix = index |> Integer.to_string() |> String.pad_leading(2, "0")

          %{
            "plugin_id" => "catalog-plugin-#{suffix}",
            "name" => "Catalog Plugin #{suffix}",
            "version" => "2.0.#{index}",
            "bundle_url" =>
              "https://github.com/carverauto/serviceradar/releases/download/v2.0.0/catalog-plugin-#{suffix}.zip",
            "upload_signature_url" =>
              "https://github.com/carverauto/serviceradar/releases/download/v2.0.0/catalog-plugin-#{suffix}.upload-signature.json",
            "bundle_digest" => Storage.sha256("catalog plugin #{suffix}"),
            "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-catalog-#{suffix}:v2.0.#{index}"
          }
        end)
    }
  end

  def bundle do
    case Application.get_env(:serviceradar_web_ng, :plugin_live_test_bundle) ||
           Process.get(:live_first_party_bundle) do
      nil ->
        path =
          Path.join(
            System.tmp_dir!(),
            "live-first-party-plugin-#{System.unique_integer([:positive])}.zip"
          )

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"plugin.yaml", @manifest_yaml},
              {~c"plugin.wasm", @wasm}
            ])

          payload = File.read!(path)
          Process.put(:live_first_party_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
    end
  end

  def upload_signature do
    case Application.get_env(:serviceradar_web_ng, :plugin_live_test_signature) ||
           Process.get(:live_first_party_signature) do
      nil ->
        signature =
          @manifest
          |> UploadSignature.verification_payload(Storage.sha256(@wasm))
          |> then(
            &:crypto.sign(:eddsa, :none, &1, [
              Process.get(:live_first_party_private_key),
              :ed25519
            ])
          )
          |> Base.encode64()

        payload = %{
          "algorithm" => "ed25519",
          "key_id" => "live-test",
          "signature" => signature
        }

        Process.put(:live_first_party_signature, payload)
        payload

      payload ->
        payload
    end
  end

  defp create_approved_package_version!(actor, plugin_id, version, opts \\ []) do
    ensure_plugin!(actor, plugin_id)

    attrs =
      maybe_put_create_attr(
        %{
          plugin_id: plugin_id,
          name: "Live #{plugin_id}",
          version: version,
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: package_manifest(plugin_id, version),
          config_schema: %{},
          display_contract: %{},
          signature: %{},
          source_type: :github,
          source_repo_url: @repo_url,
          source_commit: "test-#{plugin_id}-#{version}",
          content_hash: "sha256:#{plugin_id}-#{version}"
        },
        :producer_schedules,
        Keyword.get(opts, :producer_schedules)
      )

    assert package =
             PluginPackage
             |> Ash.Changeset.for_create(:create, attrs, actor: actor)
             |> Ash.create!()

    assert {:ok, approved} = Packages.approve(package.id, %{}, actor: actor)
    approved
  end

  defp maybe_put_create_attr(attrs, _key, nil), do: attrs
  defp maybe_put_create_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp ensure_plugin!(actor, plugin_id) do
    existing =
      Plugin
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(plugin_id == ^plugin_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Live #{plugin_id}",
          description: "LiveView test plugin"
        },
        actor: actor
      )
      |> Ash.create!()
  end

  defp package_manifest(plugin_id, version) do
    %{
      "id" => plugin_id,
      "name" => "Live #{plugin_id}",
      "version" => version,
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config"],
      "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
    }
  end

  defp register_control_session!(agent_uid, partition_id) do
    assert {:ok, _pid} =
             ProcessRegistry.register(
               {:agent_control, partition_id, agent_uid, node()},
               %{
                 agent_id: agent_uid,
                 partition_id: partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    assert_control_partition(agent_uid, partition_id, 40)
  end

  defp assert_control_partition(_agent_uid, _partition_id, 0), do: flunk("control-session partition did not converge")

  defp assert_control_partition(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_partition(agent_uid, partition_id, attempts - 1)
    end
  end

  defp unregister_control_session!(partition_id, agent_uid) do
    :ok = ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    assert_control_session_absent(agent_uid, 40)
  end

  defp assert_control_session_absent(_agent_uid, 0), do: flunk("control-session removal did not converge")

  defp assert_control_session_absent(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:error, _reason} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_session_absent(agent_uid, attempts - 1)
    end
  end

  defp quarantine_assignment!(assignment_id) do
    assignment_id = uuid_binary!(assignment_id)

    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [assignment_id]
    )
  end

  defp legacy_unbound_row?(assignment_id) do
    assignment_id = uuid_binary!(assignment_id)

    result =
      Repo.query!(
        "SELECT enabled, partition_id FROM platform.plugin_assignments WHERE id = $1",
        [assignment_id]
      )

    result.rows == [[false, nil]]
  end

  defp uuid_binary!(uuid) do
    {:ok, binary} = Ecto.UUID.dump(uuid)
    binary
  end

  defp create_plugin_target_policy!(actor, package_id) do
    PluginTargetPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Legacy policy recovery #{System.unique_integer([:positive])}",
        plugin_package_id: package_id,
        input_definitions: [],
        params_template: %{},
        interval_seconds: 60,
        timeout_seconds: 10,
        enabled: true
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_assignment!(actor, agent_uid, package_id, opts \\ []) do
    source = Keyword.get(opts, :source, :manual)
    ensure_assignment_control_session!(agent_uid)

    assert {:ok, assignment} =
             Assignments.create(
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package_id,
                 source: source,
                 source_key: source_key(source),
                 policy_id: Keyword.get(opts, :policy_id, policy_id(source)),
                 enabled: true,
                 interval_seconds: 60,
                 timeout_seconds: 10,
                 params: %{},
                 permissions_override: %{},
                 resources_override: %{}
               },
               actor: actor
             )

    assignment
  end

  defp ensure_assignment_control_session!(agent_uid) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, %{agent_id: ^agent_uid}} ->
        :ok

      _ ->
        partition_id = "test"
        register_control_session!(agent_uid, partition_id)

        on_exit(fn ->
          _ = ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
        end)
    end
  end

  defp upgraded_assignment!(actor, assignment_id) do
    assert {:ok, assignment} = Assignments.get(assignment_id, actor: actor)
    assignment
  end

  defp source_key(:policy), do: "policy:#{System.unique_integer([:positive])}"
  defp source_key(_source), do: nil

  defp policy_id(:policy), do: "policy-#{System.unique_integer([:positive])}"
  defp policy_id(_source), do: nil

  defp grant_permissions(user, permissions) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Plugin recovery LiveView #{System.unique_integer([:positive])}",
          description: "Test profile for plugin recovery permissions",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp create_repository!(name, repo_url) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

    ServiceRadar.Plugins.PluginRepository
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        repo_url: repo_url,
        index_asset_name: "serviceradar-wasm-plugin-index.json",
        signing_key_id: "#{name}-signing-key",
        signing_public_key: Base.encode64(public_key),
        enabled: true
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  # A real first-party import always records the repository it came from, and the
  # catalog is scoped by that origin, so the default has to be the built-in repo
  # rather than nil -- a nil-origin package cannot be attributed to any
  # repository and is deliberately absent from every repository's catalog.
  defp create_catalog_package!(actor, release_tag, plugin_id, version),
    do: create_catalog_package!(actor, release_tag, plugin_id, version, @repo_url)

  defp create_catalog_package!(actor, release_tag, plugin_id, version, source_repo_url) do
    ensure_plugin!(actor, plugin_id)

    assert package =
             PluginPackage
             |> Ash.Changeset.for_create(
               :create,
               %{
                 plugin_id: plugin_id,
                 name: "Live #{plugin_id}",
                 version: version,
                 entrypoint: "run_check",
                 runtime: "wasi-preview1",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: package_manifest(plugin_id, version),
                 config_schema: %{},
                 display_contract: %{},
                 signature: %{},
                 source_type: :first_party,
                 source_repo_url: source_repo_url,
                 source_release_tag: release_tag,
                 source_oci_ref: "registry.carverauto.dev/serviceradar/wasm-plugin-#{plugin_id}:#{release_tag}",
                 source_oci_digest: "sha256:#{plugin_id}-#{version}",
                 source_bundle_digest: "sha256:bundle-#{plugin_id}-#{version}",
                 content_hash: "sha256:#{plugin_id}-#{version}"
               },
               actor: actor
             )
             |> Ash.create!()

    package
  end
end
