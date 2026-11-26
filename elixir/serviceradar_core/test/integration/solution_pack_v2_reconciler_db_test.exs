defmodule ServiceRadar.Catalog.SolutionPackV2ReconcilerDbTest do
  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "reconciles v2 pack with VantagePipeline, staged/enabled DashboardPackage, immutability guard, and uninstall preserving managed: false" do
    sys_actor = SystemActor.system(:solution_pack_v2_db_test)

    {:ok, blob_pid} = Agent.start_link(fn -> %{} end)

    blob_store = %{
      put: fn key, bytes ->
        Agent.update(blob_pid, &Map.put(&1, key, bytes))
        :ok
      end,
      delete: fn key ->
        Agent.update(blob_pid, &Map.delete(&1, key))
        :ok
      end
    }

    installer_only = %{
      id: "00000000-0000-4000-8000-000000000701",
      email: "installer@example.com",
      role: :operator,
      permissions: MapSet.new(["catalog.packs.install"])
    }

    dash_admin = %{
      id: "00000000-0000-4000-8000-000000000702",
      email: "dash-admin@example.com",
      role: :admin,
      permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
    }

    renderer_js = "export default function mountSyntheticGate(){ return 'SR-0100'; }"
    files = build_v2_db_pack(renderer_js)

    # Without dashboard activation permission, requesting activation fails closed
    assert {:error, %Forbidden{}} =
             Reconciler.reconcile(files, %{},
               actor: installer_only,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    # Default install stages DashboardPackage without creating DashboardInstance
    assert {:ok, staged_res} =
             Reconciler.reconcile(files, %{"config" => %{"site_name" => "Gate West 01"}},
               actor: installer_only,
               dashboard_blob_store: blob_store
             )

    assert staged_res.installed_pack.pack_id == "io.serviceradar.synthetic-v2-db"
    assert hd(staged_res.applied_dashboard_packages).status == :staged
    assert Agent.get(blob_pid, &map_size(&1)) == 1

    {:ok, vp} =
      VantagePipeline.get_by_pipeline_version("io.serviceradar.synthetic-v2-db.plate", "1.0.0",
        actor: sys_actor
      )

    assert vp.managed == true
    assert vp.pack_id == "io.serviceradar.synthetic-v2-db"
    assert vp.signal_schema["required"] == ["plate_text"]

    # Authorized admin activates bundled DashboardPackage and binds DashboardInstance
    assert {:ok, active_res} =
             Reconciler.reconcile(files, %{"config" => %{"site_name" => "Gate West 01"}},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert hd(active_res.applied_dashboard_packages).status == :enabled
    assert active_res.has_diverged? == false
    assert hd(active_res.vantage_pipelines).action == :unchanged
    assert hd(active_res.vantage_pipelines).diverged? == false
    assert hd(active_res.applied_dashboard_packages).instance.enabled == true

    assert hd(active_res.applied_dashboard_packages).instance.settings == %{
             "site_name" => "Gate West 01"
           }

    # Conflicting hash on same (dashboard_id, version) fails closed with version_already_published
    conflicting_files =
      build_v2_db_pack("export default function tampered(){ return 'TEST-742'; }")

    assert {:error, {:version_already_published, _}} =
             Reconciler.reconcile(conflicting_files, %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    # Mark VantagePipeline as managed: false (forked) and verify uninstall preserves it
    {:ok, _} =
      vp
      |> Ash.Changeset.for_update(:update, %{managed: false}, actor: sys_actor)
      |> Ash.update(actor: sys_actor)

    assert {:ok, %{mode: :delete}} =
             Reconciler.uninstall("synthetic-v2-db",
               actor: dash_admin,
               dashboard_blob_store: blob_store
             )

    assert {:error, _} =
             InstalledSolutionPack.get_by_pack_id("io.serviceradar.synthetic-v2-db",
               actor: sys_actor
             )

    # Managed DashboardInstance and DashboardPackage removed; blob deleted
    assert [] ==
             DashboardInstance
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(route_slug == "synthetic-db-console")
             |> Ash.read!(actor: sys_actor)

    assert [] ==
             DashboardPackage
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(dashboard_id == "com.serviceradar.synthetic-db-console")
             |> Ash.read!(actor: sys_actor)

    assert Agent.get(blob_pid, &map_size(&1)) == 0

    # Forked VantagePipeline (managed: false) survives uninstall
    {:ok, survived_vp} =
      VantagePipeline.get_by_pipeline_version("io.serviceradar.synthetic-v2-db.plate", "1.0.0",
        actor: sys_actor
      )

    assert survived_vp.managed == false
  end

  test "upgrades v2 pack in CNPG with $pack_param schemas, DashboardPackage bump, and :disabled status" do
    sys_actor = SystemActor.system(:solution_pack_v2_db_upgrade_test)
    {:ok, blob_pid} = Agent.start_link(fn -> %{} end)

    blob_store = %{
      put: fn key, bytes ->
        Agent.update(blob_pid, &Map.put(&1, key, bytes))
        :ok
      end,
      delete: fn key ->
        Agent.update(blob_pid, &Map.delete(&1, key))
        :ok
      end
    }

    dash_admin = %{
      id: "00000000-0000-4000-8000-000000000703",
      email: "dash-admin-upgrade@example.com",
      role: :admin,
      permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
    }

    v1_files =
      build_v2_db_pack(
        "export default function mountDbV1(){ return 'SR-0100'; }",
        pack_slug: "synthetic-v2-db-upgrade",
        pack_id: "io.serviceradar.synthetic-v2-db-upgrade",
        pipeline_id: "io.serviceradar.synthetic-v2-db-upgrade.plate",
        dashboard_id: "com.serviceradar.synthetic-db-upgrade-console",
        route_slug: "synthetic-db-upgrade-console",
        pack_version: "1.0.0",
        dashboard_version: "1.0.0",
        paired_signal_schema?: true
      )

    assert {:ok, v1_res} =
             Reconciler.reconcile(
               v1_files,
               %{"config" => %{"site_name" => "Gate West 01"}},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert v1_res.has_diverged? == false

    {:ok, vp_v1} =
      VantagePipeline.get_by_pipeline_version(
        "io.serviceradar.synthetic-v2-db-upgrade.plate",
        "1.0.0",
        actor: sys_actor
      )

    assert vp_v1.camera_selector == %{"site" => "Gate West 01"}
    assert vp_v1.display_contract["title"] == "Gate West 01"
    assert vp_v1.signal_schema["description"] == "Gate West 01"

    # Re-apply same pack: VantagePipeline stays :unchanged and non-diverged
    assert {:ok, re_res} =
             Reconciler.reconcile(
               v1_files,
               %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert re_res.has_diverged? == false
    assert hd(re_res.vantage_pipelines).diverged? == false
    assert hd(re_res.vantage_pipelines).action == :unchanged

    # Upgrade 1.0.0 -> 1.1.0 with DashboardPackage 1.0.0 -> 2.0.0 on same route_slug (default :detach_orphan)
    v1_1_files =
      build_v2_db_pack(
        "export default function mountDbV2(){ return 'TEST-742'; }",
        pack_slug: "synthetic-v2-db-upgrade",
        pack_id: "io.serviceradar.synthetic-v2-db-upgrade",
        pipeline_id: "io.serviceradar.synthetic-v2-db-upgrade.plate",
        dashboard_id: "com.serviceradar.synthetic-db-upgrade-console",
        route_slug: "synthetic-db-upgrade-console",
        pack_version: "1.1.0",
        dashboard_version: "2.0.0",
        max_frames_per_track: 5,
        paired_signal_schema?: true
      )

    assert {:ok, v1_1_res} =
             Reconciler.reconcile(
               v1_1_files,
               %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert v1_1_res.has_diverged? == false
    assert hd(v1_1_res.vantage_pipelines).diverged? == false
    assert hd(v1_1_res.vantage_pipelines).action == :update

    {:ok, vp_v1_1} =
      VantagePipeline.get_by_pipeline_version(
        "io.serviceradar.synthetic-v2-db-upgrade.plate",
        "1.0.0",
        actor: sys_actor
      )

    assert vp_v1_1.max_frames_per_track == 5
    assert vp_v1_1.display_contract["title"] == "Gate West 01"
    assert vp_v1_1.signal_schema["description"] == "Gate West 01"

    [inst_v2] =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == "synthetic-db-upgrade-console")
      |> Ash.Query.load(:dashboard_package)
      |> Ash.read!(actor: sys_actor)

    assert inst_v2.managed == true
    assert inst_v2.pack_version == "1.1.0"
    assert inst_v2.dashboard_package.version == "2.0.0"

    # Upgrade 1.1.0 -> 1.2.0 with explicit :delete orphan decision for 2.0.0: preserves 3.0.0 instance
    v1_2_files =
      build_v2_db_pack(
        "export default function mountDbV3(){ return 'TEST-742-V3'; }",
        pack_slug: "synthetic-v2-db-upgrade",
        pack_id: "io.serviceradar.synthetic-v2-db-upgrade",
        pipeline_id: "io.serviceradar.synthetic-v2-db-upgrade.plate",
        dashboard_id: "com.serviceradar.synthetic-db-upgrade-console",
        route_slug: "synthetic-db-upgrade-console",
        pack_version: "1.2.0",
        dashboard_version: "3.0.0",
        max_frames_per_track: 6,
        paired_signal_schema?: true
      )

    assert {:ok, v1_2_res} =
             Reconciler.reconcile(
               v1_2_files,
               %{
                 "decisions" => %{
                   "dashboard_package:com.serviceradar.synthetic-db-upgrade-console:2.0.0" =>
                     "delete"
                 }
               },
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert v1_2_res.has_diverged? == false

    [inst_v3] =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == "synthetic-db-upgrade-console")
      |> Ash.Query.load(:dashboard_package)
      |> Ash.read!(actor: sys_actor)

    assert inst_v3.managed == true
    assert inst_v3.pack_version == "1.2.0"
    assert inst_v3.dashboard_package.version == "3.0.0"

    assert [] ==
             DashboardPackage
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(
               dashboard_id == "com.serviceradar.synthetic-db-upgrade-console" and
                 version == "2.0.0"
             )
             |> Ash.read!(actor: sys_actor)

    # Disable 3.0.0 package and verify re-reconcile with activate_dashboard_packages: false preserves :disabled
    [pkg_v3] =
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        dashboard_id == "com.serviceradar.synthetic-db-upgrade-console" and version == "3.0.0"
      )
      |> Ash.read!(actor: sys_actor)

    {:ok, _disabled_pkg} =
      pkg_v3
      |> Ash.Changeset.for_update(:disable, %{}, actor: sys_actor)
      |> Ash.update(actor: sys_actor)

    assert {:ok, disabled_res} =
             Reconciler.reconcile(
               v1_2_files,
               %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: false
             )

    assert hd(disabled_res.applied_dashboard_packages).status == :disabled

    # Manual structural edit to persisted VantagePipeline flags diverged?: true
    {:ok, vp_v1_2} =
      VantagePipeline.get_by_pipeline_version(
        "io.serviceradar.synthetic-v2-db-upgrade.plate",
        "1.0.0",
        actor: sys_actor
      )

    {:ok, _} =
      vp_v1_2
      |> Ash.Changeset.for_update(:update, %{object_classes: ["truck"]}, actor: sys_actor)
      |> Ash.update(actor: sys_actor)

    assert {:ok, div_res} =
             Reconciler.reconcile(
               v1_2_files,
               %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store
             )

    assert div_res.has_diverged? == true
    assert hd(div_res.vantage_pipelines).diverged? == true
    assert hd(div_res.vantage_pipelines).action == :skipped_diverged
  end

  test "reconciles built-in vantage-alpr pack with RBAC staging, paused rule, upgrade override preservation, and uninstall" do
    sys_actor = SystemActor.system(:vantage_alpr_builtin_db_test)
    {:ok, blob_pid} = Agent.start_link(fn -> %{} end)

    blob_store = %{
      put: fn key, bytes ->
        Agent.update(blob_pid, &Map.put(&1, key, bytes))
        :ok
      end,
      delete: fn key ->
        Agent.update(blob_pid, &Map.delete(&1, key))
        :ok
      end
    }

    installer_only = %{
      id: "00000000-0000-4000-8000-000000000711",
      email: "alpr-installer@example.com",
      role: :operator,
      permissions: MapSet.new(["catalog.packs.install"])
    }

    dash_admin = %{
      id: "00000000-0000-4000-8000-000000000712",
      email: "alpr-admin@example.com",
      role: :admin,
      permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
    }

    assert {:ok, pack} = BuiltinPacks.load_builtin_pack("vantage-alpr")

    # Installer without dashboard activation permission fails closed when activation requested
    assert {:error, %Forbidden{}} =
             Reconciler.reconcile(pack, %{},
               actor: installer_only,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    # Default install stages DashboardPackage, pauses watchlist rule, creates VantagePipeline/check/dashboard
    assert {:ok, staged_res} =
             Reconciler.reconcile(pack, %{},
               actor: installer_only,
               dashboard_blob_store: blob_store
             )

    assert staged_res.installed_pack.pack_id == "io.serviceradar.vantage-alpr"
    assert [%{status: :staged, instance: nil}] = staged_res.applied_dashboard_packages

    [rule] =
      StatefulAlertRule
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(name == "ALPR Synthetic Watchlist Alert")
      |> Ash.read!(actor: sys_actor)

    assert rule.enabled == false
    assert rule.managed == true

    {:ok, vp} =
      VantagePipeline.get_by_pipeline_version(
        "io.serviceradar.vantage-alpr.vehicle-plate",
        "1.0.0",
        actor: sys_actor
      )

    assert vp.managed == true
    assert vp.runner == :external_worker
    assert vp.capability == "vantage.alpr.v1"
    assert vp.fallback_runner == "camera_vlm"

    assert [%{slug: "alpr-worker-health"}] =
             DeclarativeCheck
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(slug == "alpr-worker-health")
             |> Ash.read!(actor: sys_actor)

    assert [%{slug: "alpr-overview"}] =
             AuthoredDashboard
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(slug == "alpr-overview")
             |> Ash.read!(actor: sys_actor)

    # Authorized admin activates alpr-console and binds DashboardInstance
    assert {:ok, enabled_res} =
             Reconciler.reconcile(pack, %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert [
             %{
               status: :enabled,
               instance: %DashboardInstance{route_slug: "alpr-console", enabled: true}
             }
           ] =
             enabled_res.applied_dashboard_packages

    # Operator enables watchlist rule and tunes VantagePipeline parameter_overrides; upgrade preserves both
    {:ok, _} =
      rule
      |> Ash.Changeset.for_update(
        :update,
        %{enabled: true, parameter_overrides: %{"enabled" => true}},
        actor: sys_actor
      )
      |> Ash.update(actor: sys_actor)

    {:ok, _} =
      vp
      |> Ash.Changeset.for_update(
        :update,
        %{parameter_overrides: %{"max_jobs_per_minute" => 30}},
        actor: sys_actor
      )
      |> Ash.update(actor: sys_actor)

    up_manifest =
      pack.files["manifest.json"]
      |> Jason.decode!()
      |> Map.put("version", "1.1.0")

    up_dm =
      pack.files["dashboard_packages/alpr-console/manifest.json"]
      |> Jason.decode!()
      |> Map.put("version", "1.1.0")
      |> Jason.encode!()

    up_files = Map.put(pack.files, "dashboard_packages/alpr-console/manifest.json", up_dm)
    {:ok, _, stamped_up_files} = PackManifest.refresh_manifest_digests(up_manifest, up_files)

    assert {:ok, up_res} =
             Reconciler.reconcile(stamped_up_files, %{},
               actor: dash_admin,
               dashboard_blob_store: blob_store,
               activate_dashboard_packages: true
             )

    assert up_res.installed_pack.pack_version == "1.1.0"

    [rule_after] =
      StatefulAlertRule
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(name == "ALPR Synthetic Watchlist Alert")
      |> Ash.read!(actor: sys_actor)

    assert rule_after.enabled == true

    {:ok, vp_after} =
      VantagePipeline.get_by_pipeline_version(
        "io.serviceradar.vantage-alpr.vehicle-plate",
        "1.0.0",
        actor: sys_actor
      )

    assert vp_after.parameter_overrides["max_jobs_per_minute"] == 30

    # Clean uninstall removes managed DashboardInstance/DashboardPackage/blobs and disables managed pipeline
    assert {:ok, %{mode: :delete}} =
             Reconciler.uninstall("vantage-alpr",
               actor: dash_admin,
               dashboard_blob_store: blob_store
             )

    assert Agent.get(blob_pid, &map_size(&1)) == 0
  end

  defp build_v2_db_pack(renderer_js, opts \\ []) do
    pack_slug = Keyword.get(opts, :pack_slug, "synthetic-v2-db")
    pack_id = Keyword.get(opts, :pack_id, "io.serviceradar.synthetic-v2-db")
    pipeline_id = Keyword.get(opts, :pipeline_id, "io.serviceradar.synthetic-v2-db.plate")
    dashboard_id = Keyword.get(opts, :dashboard_id, "com.serviceradar.synthetic-db-console")
    route_slug = Keyword.get(opts, :route_slug, "synthetic-db-console")
    pack_version = Keyword.get(opts, :pack_version, "1.0.0")
    dash_version = Keyword.get(opts, :dashboard_version, "1.0.0")
    max_frames = Keyword.get(opts, :max_frames_per_track)
    paired_schema? = Keyword.get(opts, :paired_signal_schema?, false)

    dash_manifest = %{
      "schema_version" => 1,
      "id" => dashboard_id,
      "name" => "Synthetic DB Console",
      "version" => dash_version,
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => PackManifest.sha256_hex(renderer_js),
        "trust" => "trusted"
      },
      "data_frames" => [
        %{"id" => "obs", "query" => "in:camera_observations", "encoding" => "json_rows"}
      ],
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }

    pipeline_doc =
      then(
        %{
          "pipeline_id" => pipeline_id,
          "version" => "1.0.0",
          "name" => "Synthetic DB Gate Plate",
          "camera_selector" => %{"site" => %{"$pack_param" => "site_name"}},
          "signal_schema_id" => "db_gate_plate",
          "signal_schema_version" => "1.0.0",
          "display_contract_id" => "db_gate_plate"
        },
        fn doc ->
          if is_integer(max_frames),
            do: Map.put(doc, "max_frames_per_track", max_frames),
            else: doc
        end
      )

    {schema_entries, schema_files} =
      if paired_schema? do
        schema_part = %{
          "schema_id" => "db_gate_plate",
          "version" => "1.0.0",
          "type" => "object",
          "description" => %{"$pack_param" => "site_name"},
          "required" => ["plate_text"],
          "properties" => %{"plate_text" => %{"type" => "string"}}
        }

        display_part = %{
          "display_contract_id" => "db_gate_plate",
          "title" => %{"$pack_param" => "site_name"}
        }

        entries = [
          %{
            "schema_id" => "db_gate_plate",
            "version" => "1.0.0",
            "schema_file" => "signal_schemas/plate.schema.json",
            "display_file" => "signal_schemas/plate.display.json"
          }
        ]

        files_map = %{
          "signal_schemas/plate.schema.json" => Jason.encode!(schema_part),
          "signal_schemas/plate.display.json" => Jason.encode!(display_part)
        }

        {entries, files_map}
      else
        schema_doc = %{
          "schema_id" => "db_gate_plate",
          "version" => "1.0.0",
          "schema" => %{
            "type" => "object",
            "required" => ["plate_text"],
            "properties" => %{"plate_text" => %{"type" => "string"}}
          },
          "display_contract" => %{"title" => "DB Gate Reads"}
        }

        entries = [
          %{
            "schema_id" => "db_gate_plate",
            "version" => "1.0.0",
            "file" => "signal_schemas/plate.json"
          }
        ]

        {entries, %{"signal_schemas/plate.json" => Jason.encode!(schema_doc)}}
      end

    manifest = %{
      "pack_format_version" => 2,
      "id" => pack_id,
      "slug" => pack_slug,
      "name" => "Synthetic V2 DB Pack",
      "version" => pack_version,
      "config" => [%{"key" => "site_name", "type" => "string", "default" => "Bay 04 Approach"}],
      "resources" => %{
        "checks" => [],
        "rules" => [],
        "dashboards" => [],
        "vantage_pipelines" => [
          %{
            "file" => "vantage_pipelines/plate.json",
            "pipeline_id" => pipeline_id
          }
        ],
        "signal_schemas" => schema_entries,
        "dashboard_packages" => [
          %{"slug" => route_slug, "route_slug" => route_slug}
        ]
      },
      "files" => %{}
    }

    base_files =
      Map.merge(
        %{
          "README.md" => "# Synthetic DB Pack\n",
          "vantage_pipelines/plate.json" => Jason.encode!(pipeline_doc),
          "dashboard_packages/#{route_slug}/manifest.json" => Jason.encode!(dash_manifest),
          "dashboard_packages/#{route_slug}/renderer.js" => renderer_js
        },
        schema_files
      )

    {:ok, _, files} = PackManifest.refresh_manifest_digests(manifest, base_files)

    files
  end
end
