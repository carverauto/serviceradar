defmodule ServiceRadar.Catalog.BuiltinPacksTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.Validations.VantageSignalSchema
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.DependencyChecker
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.Dashboards.Manifest, as: DashboardPackageManifest
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher
  alias ServiceRadar.Plugins.ConfigSchema

  @moduletag :db_free

  @expected_pack_slugs [
    "camera-semantic-search-health",
    "http-api-and-tls-posture",
    "network-segmentation-and-wan",
    "proxmox-monitoring",
    "storage-and-nvr-health",
    "vantage-alpr"
  ]

  @expected_pack_ids [
    "io.serviceradar.camera-semantic-search-health",
    "io.serviceradar.http-api-and-tls-posture",
    "io.serviceradar.network-segmentation-and-wan",
    "io.serviceradar.proxmox-monitoring",
    "io.serviceradar.storage-and-nvr-health",
    "io.serviceradar.vantage-alpr"
  ]

  defp operator_actor do
    %{
      id: "00000000-0000-4000-8000-000000000001",
      email: "operator@example.com",
      role: :operator,
      permissions:
        MapSet.new([
          "catalog.view",
          "catalog.packs.install",
          "catalog.packs.export",
          "catalog.gitops.sync"
        ])
    }
  end

  defp dash_admin_actor do
    %{
      id: "00000000-0000-4000-8000-000000000002",
      email: "dash-admin@example.com",
      role: :admin,
      permissions:
        MapSet.new([
          "catalog.view",
          "catalog.packs.install",
          "catalog.packs.export",
          "dashboards.packages.manage"
        ])
    }
  end

  defp start_mem_store do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          packs: %{},
          checks: %{},
          check_bindings: %{},
          rules: %{},
          dashboards: %{},
          vantage_pipelines: %{},
          dashboard_packages: %{},
          dashboard_instances: %{},
          dashboard_blobs: %{}
        }
      end)

    pid
  end

  describe "built-in gallery" do
    test "list_builtin_packs/0 and load_builtin_pack/1 discover and return every built-in pack cleanly" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()
      assert length(packs) == length(@expected_pack_slugs)

      slugs = Enum.map(packs, & &1.manifest["slug"])
      ids = Enum.map(packs, & &1.manifest["id"])

      assert slugs == @expected_pack_slugs
      assert ids == @expected_pack_ids

      for {slug, id} <- Enum.zip(@expected_pack_slugs, @expected_pack_ids) do
        assert {:ok, by_slug} = BuiltinPacks.load_builtin_pack(slug)
        assert {:ok, by_id} = BuiltinPacks.load_builtin_pack(id)
        assert by_slug.manifest["id"] == id
        assert by_id.manifest["slug"] == slug
      end
    end

    test "every built-in pack passes PackManifest, SecretFreeValidator, SvgSanitizer, and SchemaValidator" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()

      for pack <- packs do
        raw_manifest = Jason.decode!(pack.files["manifest.json"])

        assert {:ok, normalized_manifest} = PackManifest.validate_manifest(raw_manifest)
        expected_format = if pack.manifest["slug"] == "vantage-alpr", do: 2, else: 1
        assert normalized_manifest["pack_format_version"] == expected_format

        assert {:ok, _validated} =
                 PackManifest.validate_pack_tree(pack.files, skip_srql_nif?: true)

        assert :ok = SecretFreeValidator.validate_pack_tree(pack.files)

        assert {:ok, _clean_icon} = SvgSanitizer.validate_svg(raw_manifest["icon"])

        assert {:ok, _clean_arch} =
                 SvgSanitizer.validate_svg(pack.files["assets/architecture.svg"])

        for {path, bytes} <- pack.files do
          assert String.valid?(bytes), "expected valid UTF-8 in #{pack.manifest["slug"]}/#{path}"

          assert Enum.all?(:binary.bin_to_list(bytes), &(&1 < 128)),
                 "expected 7-bit ASCII in #{pack.manifest["slug"]}/#{path}"
        end

        for check <- pack.checks do
          assert {:ok, _normalized_check} =
                   SchemaValidator.validate_document(check.normalized, skip_srql_nif?: true)
        end
      end
    end

    test "verifies expected check topologies, rule install states, and dashboard titles for the 3 new packs" do
      {:ok, http_pack} = BuiltinPacks.load_builtin_pack("http-api-and-tls-posture")

      assert http_pack.manifest["categories"] == ["Synthetic HTTP", "Security & Posture"]

      assert Enum.map(http_pack.checks, & &1.normalized["slug"]) == [
               "http-api-journey-health",
               "tls-certificate-expiry-posture"
             ]

      assert Enum.all?(http_pack.checks, fn c ->
               SchemaValidator.classify_topology(c.normalized["nodes"]) == :edge_only
             end)

      assert Enum.map(http_pack.rules, & &1.normalized["install_state"]) == ["enabled", "paused"]
      assert hd(http_pack.dashboards).normalized["title"] == "Synthetic HTTP & TLS Posture"

      {:ok, search_pack} = BuiltinPacks.load_builtin_pack("camera-semantic-search-health")

      assert search_pack.manifest["categories"] == ["Storage & NVR", "Infrastructure"]

      assert Enum.map(search_pack.checks, & &1.normalized["slug"]) == [
               "visual-index-queue-lag",
               "media-worker-readiness"
             ]

      assert Enum.map(search_pack.checks, fn c ->
               SchemaValidator.classify_topology(c.normalized["nodes"])
             end) == [:core_only, :edge_only]

      assert length(search_pack.rules) == 2
      assert hd(search_pack.dashboards).normalized["title"] == "Camera Semantic Search Health"

      {:ok, net_pack} = BuiltinPacks.load_builtin_pack("network-segmentation-and-wan")

      assert net_pack.manifest["categories"] == ["Network & WAN", "Security & Posture"]

      assert Enum.map(net_pack.checks, & &1.normalized["slug"]) == [
               "multi-vantage-segmentation-isolation",
               "wan-dns-resolution-posture"
             ]

      assert Enum.map(net_pack.checks, fn c ->
               SchemaValidator.classify_topology(c.normalized["nodes"])
             end) == [:hybrid, :edge_only]

      assert length(net_pack.rules) == 2

      assert hd(net_pack.dashboards).normalized["title"] ==
               "Network Segmentation & WAN Resilience"
    end

    test "every built-in pack round-trips deterministically through PackArchive" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()

      for pack <- packs do
        assert {:ok, srpack_a} = PackArchive.build(pack.files)
        assert {:ok, srpack_b} = PackArchive.build(pack.files)
        assert PackManifest.sha256_hex(srpack_a) == PackManifest.sha256_hex(srpack_b)

        assert {:ok, extracted} = PackArchive.extract(srpack_a)
        assert extracted.files == pack.files
        assert extracted.manifest["id"] == pack.manifest["id"]
      end
    end

    test "every built-in pack passes Reconciler dry-run preview" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()
      actor = operator_actor()

      for pack <- packs do
        store = start_mem_store()

        assert {:ok, plan} =
                 Reconciler.preview(pack, %{},
                   actor: actor,
                   state_store: store,
                   skip_srql_nif?: true
                 )

        assert plan.dry_run == true
        assert length(plan.checks) == length(pack.checks)
        assert length(plan.rules) == length(pack.rules)
        assert length(plan.dashboards) == length(pack.dashboards)
        assert Enum.all?(plan.checks, &(&1.action == :create))
        assert Enum.all?(plan.rules, &(&1.action == :create))
        assert Enum.all?(plan.dashboards, &(&1.action == :create))

        if pack.manifest["slug"] == "vantage-alpr" do
          assert length(plan.vantage_pipelines) == 1
          assert length(plan.signal_schemas) == 1
          assert length(plan.dashboard_packages) == 1
          assert hd(plan.rules).target["enabled"] == false
        end
      end
    end
  end

  describe "vantage-alpr reference v2 pack" do
    test "validates with skip_srql_nif?: false and compiles SRQL queries via ServiceRadarSRQL.Native when loaded" do
      assert {:ok, pack} = BuiltinPacks.load_builtin_pack("vantage-alpr")

      assert {:ok, validated} =
               PackManifest.validate_pack_tree(pack.files, skip_srql_nif?: false)

      assert validated.manifest["id"] == "io.serviceradar.vantage-alpr"
      assert validated.manifest["pack_format_version"] == 2
      assert validated.manifest["license"] == "Apache-2.0"

      if Code.ensure_loaded?(ServiceRadarSRQL.Native) do
        queries =
          [
            hd(pack.checks).normalized["nodes"] |> hd() |> get_in(["config", "query"]),
            hd(pack.dashboard_packages).dashboard_manifest.data_frames
            |> hd()
            |> Map.fetch!("query")
          ] ++ Enum.map(hd(pack.dashboards).normalized["panels"], & &1["srql_query"])

        for query <- queries do
          case ServiceRadarSRQL.Native.parse_ast(query) do
            {:ok, ast_json} ->
              assert is_binary(ast_json)

            {:error, :nif_not_loaded} ->
              :ok

            other ->
              flunk("expected SRQL parse_ast ok for #{inspect(query)}, got #{inspect(other)}")
          end
        end
      end
    end

    test "satisfies Ramp 1 fallback, Ramp 2 worker matching, alpr_plate_read vectors, RuleMatcher OCSF 1008, and alpr-console parity" do
      assert {:ok, pack} = BuiltinPacks.load_builtin_pack("vantage-alpr")

      assert {:ok, ramp1} =
               DependencyChecker.check(pack.manifest,
                 worker_registrations_loader: fn _cap -> [] end
               )

      assert ramp1.ready? == true
      assert ramp1.blocking_count == 0

      assert [%{capability: "vantage.alpr.v1", status: :fallback_ready, blocking?: false}] =
               ramp1.worker_dependencies

      now = DateTime.utc_now()

      assert {:ok, ramp2} =
               DependencyChecker.check(pack.manifest,
                 now: now,
                 worker_registrations_loader: fn "vantage.alpr.v1" ->
                   [
                     %{
                       worker_id: "vantage-alpr-worker-test",
                       protocol_version: "vantage.worker.v1",
                       capabilities: ["vantage.alpr.v1"],
                       health: :ready,
                       expires_at: DateTime.shift(now, minute: 2)
                     }
                   ]
                 end
               )

      assert ramp2.ready? == true
      assert [%{capability: "vantage.alpr.v1", status: :satisfied}] = ramp2.worker_dependencies

      [schema_item] = pack.signal_schemas
      assert schema_item.schema_id == "alpr_plate_read"

      assert :ok ==
               VantageSignalSchema.validate_attributes(
                 schema_item.signal_schema,
                 %{
                   "plate_text" => "SR-0100",
                   "region" => "US-CO",
                   "vehicle_color" => "silver",
                   "vehicle_type" => "sedan",
                   "confidence" => 0.94
                 }
               )

      assert :ok ==
               VantageSignalSchema.validate_attributes(
                 schema_item.signal_schema,
                 %{"plate_text" => "TEST-742", "region" => "US-CA", "confidence" => 0.91}
               )

      for bad <- [
            %{"plate_text" => "sr-0100", "region" => "US-CO"},
            %{"plate_text" => "A"},
            %{"plate_text" => "SR-0100-12345"},
            %{"plate_text" => "SR-0100", "unexpected" => true}
          ] do
        assert {:error, :signal_schema_violation} ==
                 VantageSignalSchema.validate_attributes(schema_item.signal_schema, bad)
      end

      [rule] = pack.rules
      assert rule.normalized["install_state"] == "paused"
      assert RuleMatcher.unknown_match_keys(rule.normalized["match"]) == []

      rule_struct = %{signal: :event, match: rule.normalized["match"]}

      matching_event = %{
        log_name: "camera.vantage.observation",
        log_provider: "serviceradar.vantage",
        metadata: %{
          "service_radar" => %{
            "signal_schema" => %{"schema_id" => "alpr_plate_read"},
            "attributes" => %{"plate_text" => "SR-0100"}
          }
        }
      }

      second_matching_event =
        put_in(
          matching_event,
          [:metadata, "service_radar", "attributes", "plate_text"],
          "TEST-742"
        )

      non_matching_plate =
        put_in(
          matching_event,
          [:metadata, "service_radar", "attributes", "plate_text"],
          "ZZ-9999"
        )

      non_matching_schema =
        put_in(
          matching_event,
          [:metadata, "service_radar", "signal_schema", "schema_id"],
          "other"
        )

      assert RuleMatcher.rule_matches_event?(matching_event, rule_struct)
      assert RuleMatcher.rule_matches_event?(second_matching_event, rule_struct)
      refute RuleMatcher.rule_matches_event?(non_matching_plate, rule_struct)
      refute RuleMatcher.rule_matches_event?(non_matching_schema, rule_struct)

      [dp] = pack.dashboard_packages
      assert dp.slug == "alpr-console"
      assert dp.dashboard_id == "io.serviceradar.alpr-console"
      assert byte_size(dp.renderer_bytes) <= PackManifest.max_renderer_bytes()
      assert dp.renderer_sha256 == PackManifest.sha256_hex(dp.renderer_bytes)
      assert dp.renderer_sha256 == pack.manifest["files"][dp.renderer_path]
      assert {:ok, parsed_dm} = DashboardPackageManifest.from_json(dp.manifest_bytes)
      assert parsed_dm.renderer["trust"] == "trusted"
      assert parsed_dm.renderer["interface_version"] == "dashboard-browser-module-v1"
      assert :ok == ConfigSchema.validate_schema(parsed_dm.settings_schema)
      assert String.contains?(dp.renderer_bytes, "mountDashboard")
    end

    test "reconciles in-memory with RBAC staging, paused rule, immutability, and clean uninstall" do
      assert {:ok, pack} = BuiltinPacks.load_builtin_pack("vantage-alpr")
      store = start_mem_store()
      installer = operator_actor()
      admin = dash_admin_actor()

      assert {:ok, staged} =
               Reconciler.reconcile(pack, %{},
                 actor: installer,
                 state_store: store,
                 skip_srql_nif?: true
               )

      assert staged.installed_pack.pack_id == "io.serviceradar.vantage-alpr"
      assert hd(staged.applied_dashboard_packages).status == :staged
      assert Agent.get(store, &map_size(&1.dashboard_instances)) == 0

      assert Agent.get(
               store,
               &get_in(&1, [
                 :rules,
                 {"stateful_alert_rule", "ALPR Synthetic Watchlist Alert"},
                 "enabled"
               ])
             ) ==
               false

      assert {:ok, enabled} =
               Reconciler.reconcile(pack, %{},
                 actor: admin,
                 state_store: store,
                 activate_dashboard_packages: true,
                 skip_srql_nif?: true
               )

      assert hd(enabled.applied_dashboard_packages).status == :enabled

      assert Agent.get(store, &get_in(&1, [:dashboard_instances, "alpr-console", :enabled])) ==
               true

      tampered_renderer = "export function mountDashboard(){}\nexport default mountDashboard;\n"

      tampered_dm =
        pack.files["dashboard_packages/alpr-console/manifest.json"]
        |> Jason.decode!()
        |> put_in(["renderer", "sha256"], PackManifest.sha256_hex(tampered_renderer))
        |> Jason.encode!()

      tampered_raw_files =
        pack.files
        |> Map.put("dashboard_packages/alpr-console/renderer.js", tampered_renderer)
        |> Map.put("dashboard_packages/alpr-console/manifest.json", tampered_dm)

      {:ok, _, tampered_files} =
        PackManifest.refresh_manifest_digests(
          Jason.decode!(pack.files["manifest.json"]),
          tampered_raw_files
        )

      assert {:error, {:version_already_published, _}} =
               Reconciler.reconcile(tampered_files, %{},
                 actor: admin,
                 state_store: store,
                 activate_dashboard_packages: true,
                 skip_srql_nif?: true
               )

      assert {:ok, %{mode: :delete}} =
               Reconciler.uninstall("vantage-alpr", actor: admin, state_store: store)

      assert Agent.get(store, &map_size(&1.packs)) == 0
      assert Agent.get(store, &map_size(&1.dashboard_instances)) == 0
      assert Agent.get(store, &map_size(&1.dashboard_packages)) == 0
    end
  end
end
