defmodule ServiceRadar.Catalog.ReconcilerAndSyncTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.CatalogNotifier
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.CatalogSyncWorker
  alias ServiceRadar.Catalog.DependencyChecker
  alias ServiceRadar.Catalog.GitOpsTreeClient
  alias ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackExporter
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Catalog.ReleaseCatalogClient
  alias ServiceRadar.Catalog.UploadSignature
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.PackSeeder
  alias ServiceRadar.Identity.RBAC.Catalog, as: RBACCatalog
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.ZenRule

  @moduletag :db_free

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

  defp viewer_actor do
    %{
      id: "00000000-0000-4000-8000-000000000002",
      email: "viewer@example.com",
      role: :viewer,
      permissions: MapSet.new(["catalog.view"])
    }
  end

  defp start_mem_store do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{packs: %{}, checks: %{}, check_bindings: %{}, rules: %{}, dashboards: %{}}
      end)

    pid
  end

  defp build_test_pack(version, opts \\ []) do
    extra_node? = Keyword.get(opts, :extra_node?, false)
    rule_install_state = Keyword.get(opts, :rule_install_state, "paused")
    required_slot? = Keyword.get(opts, :required_slot?, true)
    plugin_deps = Keyword.get(opts, :plugin_dependencies, [])

    nodes =
      if extra_node? do
        [
          %{
            "id" => "posture_1",
            "kind" => "platform_posture",
            "label" => "Entitlement v2",
            "config" => %{
              "evaluator" => "storage.entitlement_utilization",
              "consumer" => "recordings"
            }
          },
          %{
            "id" => "extract_1",
            "kind" => "extract_field",
            "label" => "Extract Utilization",
            "config" => %{
              "source_type" => "field",
              "field" => "utilization_percent"
            }
          },
          %{
            "id" => "assert_1",
            "kind" => "threshold_assert",
            "label" => "Thresholds v2",
            "config" => %{
              "field" => "utilization_percent",
              "warn" => %{"op" => ">=", "value" => "{{inputs.utilization_warn_pct}}"},
              "crit" => %{"op" => ">=", "value" => 95.0}
            }
          },
          %{
            "id" => "out_1",
            "kind" => "alert_output",
            "label" => "Verdict v2",
            "config" => %{}
          }
        ]
      else
        [
          %{
            "id" => "posture_1",
            "kind" => "platform_posture",
            "label" => "Entitlement",
            "config" => %{"evaluator" => "storage.entitlement_utilization"}
          },
          %{
            "id" => "assert_1",
            "kind" => "threshold_assert",
            "label" => "Thresholds",
            "config" => %{
              "field" => "utilization_percent",
              "warn" => %{"op" => ">=", "value" => "{{inputs.utilization_warn_pct}}"}
            }
          },
          %{
            "id" => "out_1",
            "kind" => "alert_output",
            "label" => "Verdict",
            "config" => %{}
          }
        ]
      end

    edges =
      if extra_node? do
        [
          %{
            "id" => "e1",
            "source" => "posture_1",
            "source_handle" => "signal",
            "target" => "extract_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e2",
            "source" => "extract_1",
            "source_handle" => "value",
            "target" => "assert_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e3",
            "source" => "assert_1",
            "source_handle" => "verdict",
            "target" => "out_1",
            "target_handle" => "in"
          }
        ]
      else
        [
          %{
            "id" => "e1",
            "source" => "posture_1",
            "source_handle" => "signal",
            "target" => "assert_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e2",
            "source" => "assert_1",
            "source_handle" => "verdict",
            "target" => "out_1",
            "target_handle" => "in"
          }
        ]
      end

    slots =
      if required_slot? do
        [
          %{
            "slot" => "target_http_api",
            "provider" => "generic_http",
            "role" => "bearer_token",
            "purpose" => "Synthetic health auth",
            "required" => true
          }
        ]
      else
        []
      end

    check_doc = %{
      "schema_version" => 1,
      "slug" => "wan-edge-posture",
      "name" => "WAN Edge Posture",
      "state" => "enabled",
      "inputs" => [
        %{
          "key" => "utilization_warn_pct",
          "type" => "number",
          "default" => %{"$pack_param" => "utilization_warn_pct"},
          "min" => 1.0,
          "max" => 100.0
        }
      ],
      "credential_slots" => slots,
      "nodes" => nodes,
      "edges" => edges
    }

    rule_doc = %{
      "kind" => "stateful_alert_rule",
      "name" => "wan_edge_high_latency",
      "install_state" => rule_install_state,
      "signal" => "event",
      "match" => %{
        "subject_prefix" => "declarative_check.health.state_change",
        "attribute_equals" => %{"check_slug" => "wan-edge-posture", "to_status" => "down"}
      },
      "group_by" => ["check_slug"],
      "threshold" => 1,
      "window_seconds" => 300,
      "bucket_seconds" => 60,
      "cooldown_seconds" => 300,
      "renotify_seconds" => 21_600,
      "event" => %{"log_name" => "health.wan_edge"},
      "alert" => %{"severity" => if(extra_node?, do: "critical", else: "high")}
    }

    dash_doc = %{
      "version" => 1,
      "slug" => "wan-edge-overview",
      "title" => if(extra_node?, do: "WAN Edge Overview v2", else: "WAN Edge Overview"),
      "default_time_range" => "last_1h",
      "panels" => [
        %{
          "title" => "Healthy Services",
          "srql_query" => "in:services stats:\"count() as total\"",
          "visual_type" => "stat",
          "data_binding" => %{"value" => "total"},
          "layout" => %{"x" => 0, "y" => 0, "w" => if(extra_node?, do: 12, else: 6), "h" => 3},
          "position" => 0
        }
      ]
    }

    {:ok, tree} =
      PackExporter.export_tree(%{
        id: "io.example.wan-edge-sla",
        slug: "wan-edge-sla",
        name: "WAN Edge SLA",
        version: version,
        config: [
          %{
            "key" => "utilization_warn_pct",
            "type" => "number",
            "required" => false,
            "default" => 85.0,
            "min" => 1.0,
            "max" => 100.0,
            "description" => "Warn pct"
          }
        ],
        credential_slots: slots,
        plugin_dependencies: plugin_deps,
        checks: [check_doc],
        rules: [rule_doc],
        dashboards: [dash_doc]
      })

    # Re-inject $pack_param into the exported check template so parameter resolution is exercised
    raw_check =
      tree["checks/wan-edge-posture.json"]
      |> Jason.decode!()
      |> put_in(["inputs", Access.at(0), "default"], %{"$pack_param" => "utilization_warn_pct"})
      |> Jason.encode!(pretty: true)

    manifest = Jason.decode!(tree["manifest.json"])

    {:ok, _m, refreshed_tree} =
      PackManifest.refresh_manifest_digests(
        manifest,
        Map.put(tree, "checks/wan-edge-posture.json", raw_check <> "\n")
      )

    refreshed_tree
  end

  describe "PackSeeder installs the shipped pack files through the reconciler" do
    @storage_pack "io.serviceradar.storage-and-nvr-health"

    test "a deployment with nothing installed gets the pack, its checks and its rules" do
      store = start_mem_store()
      {:ok, shipped} = BuiltinPacks.get_pack("storage-and-nvr-health")

      assert {:ok, [%{slug: "storage-and-nvr-health", action: :installed}]} =
               PackSeeder.seed_builtin_packs(state_store: store)

      state = Agent.get(store, & &1)
      installed = state.packs[@storage_pack]

      assert installed.pack_version == shipped.manifest["version"]
      assert installed.source_type == :builtin

      assert state.checks |> Map.keys() |> Enum.sort() ==
               shipped.checks |> Enum.map(& &1.normalized["slug"]) |> Enum.sort()

      assert state.rules |> Map.keys() |> Enum.sort() ==
               shipped.rules
               |> Enum.map(&{"stateful_alert_rule", &1.normalized["name"]})
               |> Enum.sort()
    end

    test "seeding again keeps every check and rule as installed, and then settles" do
      store = start_mem_store()
      {:ok, _} = PackSeeder.seed_builtin_packs(state_store: store)
      first = Agent.get(store, & &1)

      assert {:ok, [%{action: :reapplied}]} = PackSeeder.seed_builtin_packs(state_store: store)
      second = Agent.get(store, & &1)

      assert second.checks == first.checks

      # A re-apply records each rule's enabled state as an operator override;
      # nothing that decides when the rule fires may change.
      for {key, rule} <- first.rules do
        assert Map.delete(second.rules[key], "parameter_overrides") ==
                 Map.delete(rule, "parameter_overrides")
      end

      assert {:ok, [%{action: :reapplied}]} = PackSeeder.seed_builtin_packs(state_store: store)
      third = Agent.get(store, & &1)

      assert third.checks == second.checks
      assert third.rules == second.rules
    end

    test "a newer pack the operator installed from a catalog is left alone" do
      store = start_mem_store()
      {:ok, _} = PackSeeder.seed_builtin_packs(state_store: store)

      Agent.update(store, fn state ->
        update_in(state, [:packs, @storage_pack], fn pack ->
          %{pack | pack_version: "9.0.0", source_type: :release_catalog}
        end)
      end)

      before = Agent.get(store, & &1)

      assert {:ok, [%{action: :kept_installed}]} =
               PackSeeder.seed_builtin_packs(state_store: store)

      assert Agent.get(store, & &1) == before
    end

    test "thresholds tuned under the earlier seeder's parameter names carry over to the pack's names" do
      earlier_silence_check = %{
        inputs: [
          %{"key" => "silence_window_minutes", "type" => "integer", "min" => 1, "max" => 1440}
        ],
        parameter_overrides: %{"silence_window_minutes" => 2}
      }

      [earlier_silence_input] = earlier_silence_check.inputs
      stored_silence = earlier_silence_check.parameter_overrides["silence_window_minutes"]
      assert stored_silence in earlier_silence_input["min"]..earlier_silence_input["max"]

      tuned = [
        %{parameter_overrides: %{"warn_percent" => 70, "crit_percent" => 88}},
        %{parameter_overrides: %{"warn_share_percent" => 40}},
        %{parameter_overrides: %{"max_report_age_hours" => 48}},
        earlier_silence_check,
        %{parameter_overrides: %{}}
      ]

      carried = PackSeeder.carried_config(tuned)

      assert carried == %{
               "utilization_warn_pct" => 70,
               "utilization_crit_pct" => 88,
               "hold_warn_share_pct" => 40,
               "max_report_age_hours" => 48,
               "silence_window_minutes" => 2
             }

      # The carried values are ones the shipped pack accepts as configuration.
      store = start_mem_store()
      {:ok, shipped} = BuiltinPacks.get_pack("storage-and-nvr-health")

      assert {:ok, _} =
               Reconciler.reconcile(shipped, %{"config" => carried},
                 actor: operator_actor(),
                 state_store: store
               )

      utilization = Agent.get(store, & &1.checks["storage-entitlement-utilization"])

      assert utilization["parameter_overrides"] == %{
               "utilization_warn_pct" => 70,
               "utilization_crit_pct" => 88
             }

      silence = Agent.get(store, & &1.checks["camera-continuous-recording-silence"])
      assert silence["parameter_overrides"] == %{"silence_window_minutes" => 2}
    end

    test "the seeder never moves an installed pack backwards or takes over another source's install" do
      for {installed, shipped, expected} <- [
            {nil, "0.1.1", :installed},
            {%{pack_version: "0.1.0", source_type: :builtin}, "0.1.1", :upgraded},
            {%{pack_version: "0.1.0", source_type: :release_catalog}, "0.1.1", :upgraded},
            {%{pack_version: "0.1.1", source_type: :builtin}, "0.1.1", :reapplied},
            {%{pack_version: "0.1.1", source_type: :release_catalog}, "0.1.1", :kept_installed},
            {%{pack_version: "0.2.0", source_type: :builtin}, "0.1.1", :kept_installed},
            {%{pack_version: "not-a-version", source_type: :builtin}, "0.1.1", :kept_installed}
          ] do
        assert PackSeeder.seed_action(installed, shipped) == expected
      end
    end
  end

  describe "DependencyChecker Wasm plugin approval enforcement" do
    test "satisfies approved matching SemVer and refuses staged/missing without auto-approval" do
      deps = [
        %{
          "package_id" => "io.example.wireless-controller",
          "version_constraint" => ">= 0.2.0 and < 1.0.0",
          "required" => true
        }
      ]

      approved_loader = fn "io.example.wireless-controller" ->
        [%{plugin_id: "io.example.wireless-controller", version: "0.2.1", status: :approved}]
      end

      assert {:ok,
              %{ready?: true, dependencies: [%{status: :satisfied, matched_version: "0.2.1"}]}} =
               DependencyChecker.check(deps, plugin_packages_loader: approved_loader)

      staged_loader = fn "io.example.wireless-controller" ->
        [%{plugin_id: "io.example.wireless-controller", version: "0.3.0", status: :staged}]
      end

      assert {:ok,
              %{
                ready?: false,
                dependencies: [
                  %{
                    status: :staged_approval_required,
                    review_path: "/settings/agents/plugins"
                  }
                ]
              }} = DependencyChecker.check(deps, plugin_packages_loader: staged_loader)

      pack_with_dep = build_test_pack("0.1.0", required_slot?: false, plugin_dependencies: deps)
      store = start_mem_store()

      assert {:error, {:unsatisfied_plugin_dependencies, [%{status: :staged_approval_required}]}} =
               Reconciler.reconcile(pack_with_dep, %{},
                 actor: operator_actor(),
                 state_store: store,
                 plugin_packages_loader: staged_loader
               )
    end
  end

  describe "Reconciler guided install, paused rules, parameter_overrides, and 0.1.0 -> 0.2.0 upgrades" do
    test "refuses active install when required credential_slot is unbound, and forbids viewer installs" do
      pack_v1 = build_test_pack("0.1.0")
      store = start_mem_store()

      assert {:error, %Forbidden{}} =
               Reconciler.reconcile(pack_v1, %{}, actor: viewer_actor(), state_store: store)

      assert {:error, {:missing_required_credential_slots, ["target_http_api"]}} =
               Reconciler.reconcile(pack_v1, %{}, actor: operator_actor(), state_store: store)
    end

    test "preserves parameter_overrides, paused rule state, and credential bindings on 0.1.0 -> 0.2.0 while protecting diverged resources" do
      store = start_mem_store()
      pack_v1 = build_test_pack("0.1.0", rule_install_state: "paused")
      rule_uuid = "00000000-0000-4000-8000-000000000010"

      install_params = %{
        "config" => %{"utilization_warn_pct" => 80.0},
        "credential_bindings" => %{
          "target_http_api" => %{"credential_rule_id" => rule_uuid}
        }
      }

      assert {:ok, v1_res} =
               Reconciler.reconcile(pack_v1, install_params,
                 actor: operator_actor(),
                 state_store: store
               )

      assert v1_res.mode == :install

      state_after_v1 = Agent.get(store, & &1)
      installed_check = state_after_v1.checks["wan-edge-posture"]
      assert installed_check["pack_version"] == "0.1.0"
      assert installed_check["managed"] == true
      assert installed_check["parameter_overrides"] == %{"utilization_warn_pct" => 80.0}

      assert state_after_v1.check_bindings["wan-edge-posture"]["target_http_api"].credential_rule_id ==
               rule_uuid

      installed_rule = state_after_v1.rules[{"stateful_alert_rule", "wan_edge_high_latency"}]
      assert installed_rule["enabled"] == false
      assert installed_rule["parameter_overrides"]["enabled"] == false

      # Upgrade to 0.2.0 (unmodified resources -> upgraded with overrides & paused state preserved!)
      pack_v2 = build_test_pack("0.2.0", extra_node?: true, rule_install_state: "paused")

      assert {:ok, v2_res} =
               Reconciler.reconcile(pack_v2, %{},
                 actor: operator_actor(),
                 state_store: store
               )

      assert v2_res.mode == :upgrade
      assert Enum.all?(v2_res.checks, &(&1.action == :update))

      state_after_v2 = Agent.get(store, & &1)
      upgraded_check = state_after_v2.checks["wan-edge-posture"]
      assert upgraded_check["pack_version"] == "0.2.0"
      assert length(upgraded_check["nodes"]) == 4
      assert upgraded_check["parameter_overrides"] == %{"utilization_warn_pct" => 80.0}

      assert state_after_v2.check_bindings["wan-edge-posture"]["target_http_api"].credential_rule_id ==
               rule_uuid

      upgraded_rule = state_after_v2.rules[{"stateful_alert_rule", "wan_edge_high_latency"}]
      assert upgraded_rule["enabled"] == false
      assert upgraded_rule["alert"]["severity"] == "critical"

      # Now structurally customize the check DAG and upgrade to 0.3.0 -> protected!
      Agent.update(store, fn st ->
        put_in(st, [:checks, "wan-edge-posture", "nodes"], [
          %{
            "id" => "custom_1",
            "kind" => "platform_posture",
            "label" => "Operator Custom Node",
            "config" => %{"evaluator" => "storage.hold_pin_pressure"}
          }
        ])
      end)

      pack_v3 = build_test_pack("0.3.0", extra_node?: true)

      assert {:ok, v3_res} =
               Reconciler.reconcile(pack_v3, %{},
                 actor: operator_actor(),
                 state_store: store
               )

      assert [%{slug: "wan-edge-posture", action: :skipped_diverged, diverged?: true}] =
               v3_res.checks

      custom_nodes = Agent.get(store, & &1.checks["wan-edge-posture"]["nodes"])
      assert hd(custom_nodes)["id"] == "custom_1"

      # Explicit reset_to_upstream re-attaches and restores upstream structure while keeping overrides!
      assert {:ok, reset_res} =
               Reconciler.reconcile(
                 pack_v3,
                 %{"decisions" => %{"check:wan-edge-posture" => "reset_to_upstream"}},
                 actor: operator_actor(),
                 state_store: store
               )

      assert [%{slug: "wan-edge-posture", action: :reset_to_upstream}] = reset_res.checks
      reset_check = Agent.get(store, & &1.checks["wan-edge-posture"])
      assert reset_check["pack_version"] == "0.3.0"
      assert length(reset_check["nodes"]) == 4
      assert reset_check["parameter_overrides"] == %{"utilization_warn_pct" => 80.0}
    end
  end

  describe "ReleaseCatalogClient per-repository Ed25519 trust isolation, portal support, and PAT handling" do
    test "verifies signed release bundles, isolates keys across repositories, and supports developer.serviceradar.cloud portal URLs" do
      seed_a = :binary.copy(<<0x21>>, 32)
      {pub_a, _} = :crypto.generate_key(:eddsa, :ed25519, seed_a)
      seed_b = :binary.copy(<<0x22>>, 32)
      {pub_b, _} = :crypto.generate_key(:eddsa, :ed25519, seed_b)

      {:ok, builtin} = BuiltinPacks.get_pack("storage-and-nvr-health")
      {:ok, srpack_bytes} = PackArchive.build(builtin.files)
      bundle_hash = PackManifest.sha256_hex(srpack_bytes)

      {:ok, sig_a} =
        UploadSignature.sign(builtin.manifest, bundle_hash, seed_a, key_id: "publisher-key")

      index_payload =
        Jason.encode!(%{
          "format_version" => 1,
          "packs" => [
            %{
              "id" => builtin.manifest["id"],
              "slug" => builtin.manifest["slug"],
              "version" => builtin.manifest["version"],
              "bundle_url" =>
                "https://developer.serviceradar.cloud/packs/storage-and-nvr-health-0.1.0.srpack",
              "upload_signature_url" =>
                "https://developer.serviceradar.cloud/packs/storage-and-nvr-health-0.1.0.srpack.sig",
              "bundle_digest" => bundle_hash,
              "manifest" => builtin.manifest
            }
          ]
        })

      portal_fetcher = fn url, _opts ->
        cond do
          url == "https://developer.serviceradar.cloud/packs/index.json" ->
            {:ok, %Req.Response{status: 200, body: index_payload}}

          String.ends_with?(url, ".srpack") ->
            {:ok, %Req.Response{status: 200, body: srpack_bytes}}

          String.ends_with?(url, ".srpack.sig") ->
            {:ok, %Req.Response{status: 200, body: Jason.encode!(sig_a)}}
        end
      end

      repo_a = %{
        id: "00000000-0000-4000-8000-000000000101",
        repo_url: "https://developer.serviceradar.cloud",
        provider_type: :portal,
        mode: :release_catalog,
        signing_key_id: "publisher-key",
        signing_public_key: Base.encode64(pub_a),
        credential_secret_id: nil
      }

      repo_b = %{
        repo_a
        | id: "00000000-0000-4000-8000-000000000102",
          signing_public_key: Base.encode64(pub_b)
      }

      assert {:ok, imported} =
               ReleaseCatalogClient.fetch_and_verify_pack(
                 repo_a,
                 "storage-and-nvr-health",
                 http_fetch_body: portal_fetcher
               )

      assert imported.pack.manifest["id"] == "io.serviceradar.storage-and-nvr-health"

      # Serving bundle signed by repo A's key from repo B fails with :invalid_signature before extraction!
      corrupt_bytes_with_same_hash_ignored = "NOT_EVEN_A_ZSTD_ARCHIVE"
      tampered_hash = PackManifest.sha256_hex(corrupt_bytes_with_same_hash_ignored)

      {:ok, sig_a_on_corrupt} =
        UploadSignature.sign(builtin.manifest, tampered_hash, seed_a, key_id: "publisher-key")

      tampered_index =
        Jason.encode!(%{
          "format_version" => 1,
          "packs" => [
            %{
              "id" => builtin.manifest["id"],
              "slug" => builtin.manifest["slug"],
              "version" => builtin.manifest["version"],
              "bundle_url" => "https://developer.serviceradar.cloud/packs/bad.srpack",
              "upload_signature_url" =>
                "https://developer.serviceradar.cloud/packs/bad.srpack.sig",
              "bundle_digest" => tampered_hash,
              "manifest" => builtin.manifest
            }
          ]
        })

      repo_b_fetcher = fn url, _opts ->
        cond do
          url == "https://developer.serviceradar.cloud/packs/index.json" ->
            {:ok, %Req.Response{status: 200, body: tampered_index}}

          String.ends_with?(url, ".srpack") ->
            {:ok, %Req.Response{status: 200, body: corrupt_bytes_with_same_hash_ignored}}

          String.ends_with?(url, ".srpack.sig") ->
            {:ok, %Req.Response{status: 200, body: Jason.encode!(sig_a_on_corrupt)}}
        end
      end

      assert {:error, :invalid_signature} =
               ReleaseCatalogClient.fetch_and_verify_pack(
                 repo_b,
                 "storage-and-nvr-health",
                 http_fetch_body: repo_b_fetcher
               )
    end

    test "private GitHub release catalog attaches PAT to API asset URL and strips auth on cross-origin host" do
      seed = :binary.copy(<<0x33>>, 32)
      {pub, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
      {:ok, builtin} = BuiltinPacks.get_pack("storage-and-nvr-health")
      {:ok, srpack_bytes} = PackArchive.build(builtin.files)
      bundle_hash = PackManifest.sha256_hex(srpack_bytes)
      {:ok, sig} = UploadSignature.sign(builtin.manifest, bundle_hash, seed, key_id: "corp-v1")

      index_json =
        Jason.encode!(%{
          "packs" => [
            %{
              "id" => builtin.manifest["id"],
              "slug" => builtin.manifest["slug"],
              "version" => builtin.manifest["version"],
              "bundle_file" => "storage-and-nvr-health-0.1.0.srpack",
              "bundle_url" => "https://objects.example.com/presigned/pack.srpack",
              "signature_file" => "storage-and-nvr-health-0.1.0.srpack.sig",
              "upload_signature_url" => "https://objects.example.com/presigned/pack.srpack.sig",
              "bundle_digest" => bundle_hash,
              "manifest" => builtin.manifest
            }
          ]
        })

      release_json =
        Jason.encode!(%{
          "tag_name" => "v0.1.0",
          "assets" => [
            %{
              "name" => "serviceradar-pack-index.json",
              "url" => "https://api.github.com/repos/example/private-packs/releases/assets/1"
            },
            %{
              "name" => "storage-and-nvr-health-0.1.0.srpack",
              "url" => "https://api.github.com/repos/example/private-packs/releases/assets/2"
            }
          ]
        })

      test_pid = self()

      fetcher = fn url, opts ->
        headers = Map.new(opts[:headers] || [], fn {k, v} -> {String.downcase(k), v} end)
        send(test_pid, {:http_call, url, headers})

        cond do
          String.ends_with?(url, "/releases/latest") ->
            {:ok, %Req.Response{status: 200, body: release_json}}

          String.ends_with?(url, "/assets/1") ->
            {:ok, %Req.Response{status: 200, body: index_json}}

          String.ends_with?(url, "/assets/2") ->
            {:ok, %Req.Response{status: 200, body: srpack_bytes}}

          url == "https://objects.example.com/presigned/pack.srpack.sig" ->
            {:ok, %Req.Response{status: 200, body: Jason.encode!(sig)}}
        end
      end

      private_repo = %{
        id: "00000000-0000-4000-8000-000000000103",
        repo_url: "https://github.com/example/private-packs",
        provider_type: :github,
        mode: :release_catalog,
        index_asset_name: "serviceradar-pack-index.json",
        signing_key_id: "corp-v1",
        signing_public_key: Base.encode64(pub),
        credential_secret_id: "00000000-0000-4000-8000-000000000199"
      }

      assert {:ok, _} =
               ReleaseCatalogClient.fetch_and_verify_pack(
                 private_repo,
                 "storage-and-nvr-health",
                 token_resolver: fn _ -> {:ok, "synthetic-pat-value"} end,
                 http_fetch_body: fetcher
               )

      assert_receive {:http_call,
                      "https://api.github.com/repos/example/private-packs/releases/assets/2",
                      api_headers}

      assert api_headers["authorization"] == "Bearer synthetic-pat-value"
      assert api_headers["accept"] == "application/octet-stream"

      assert_receive {:http_call, "https://objects.example.com/presigned/pack.srpack.sig",
                      cross_origin_headers}

      refute Map.has_key?(cross_origin_headers, "authorization")
    end
  end

  describe "GitOpsTreeClient pure-HTTPS push, conflict detection, and pull across GitHub, GitLab, and Gitea" do
    test "pushes PR on GitHub, detects non-fast-forward conflict on direct_commit, and pulls preview + apply" do
      pack_v2 = build_test_pack("0.2.0", required_slot?: false, extra_node?: true)
      parent_sha = String.duplicate("a1", 20)
      tree_sha = String.duplicate("b2", 20)
      commit_sha = String.duplicate("c3", 20)
      test_pid = self()

      blobs_by_sha =
        pack_v2
        |> Enum.with_index(1)
        |> Map.new(fn {{rel, bytes}, idx} ->
          sha = String.pad_leading(Integer.to_string(idx, 16), 40, "0")
          {sha, {"packs/wan-edge-sla/#{rel}", bytes}}
        end)

      github_mock = fn method, url, body, _opts ->
        send(test_pid, {:gh_req, method, url, body})

        cond do
          method == :get and String.ends_with?(url, "/git/ref/heads/main") ->
            {:ok, %Req.Response{status: 200, body: %{"object" => %{"sha" => parent_sha}}}}

          method == :get and String.contains?(url, "/git/commits/") ->
            {:ok, %Req.Response{status: 200, body: %{"tree" => %{"sha" => tree_sha}}}}

          method == :get and String.contains?(url, "/git/trees/") ->
            tree_items =
              Enum.map(blobs_by_sha, fn {sha, {path, bytes}} ->
                %{"path" => path, "type" => "blob", "sha" => sha, "size" => byte_size(bytes)}
              end)

            {:ok, %Req.Response{status: 200, body: %{"tree" => tree_items}}}

          method == :get and String.contains?(url, "/git/blobs/") ->
            sha = url |> String.split("/") |> List.last()
            {_path, bytes} = Map.fetch!(blobs_by_sha, sha)

            {:ok,
             %Req.Response{
               status: 200,
               body: %{"content" => Base.encode64(bytes), "encoding" => "base64"}
             }}

          method == :post and String.ends_with?(url, "/git/blobs") ->
            {:ok, %Req.Response{status: 201, body: %{"sha" => String.duplicate("d4", 20)}}}

          method == :post and String.ends_with?(url, "/git/trees") ->
            {:ok, %Req.Response{status: 201, body: %{"sha" => String.duplicate("e5", 20)}}}

          method == :post and String.ends_with?(url, "/git/commits") ->
            {:ok, %Req.Response{status: 201, body: %{"sha" => commit_sha}}}

          method == :post and String.ends_with?(url, "/git/refs") ->
            {:ok, %Req.Response{status: 201, body: %{"ref" => body["ref"]}}}

          method == :post and String.ends_with?(url, "/pulls") ->
            {:ok,
             %Req.Response{
               status: 201,
               body: %{"html_url" => "https://github.com/example/gitops/pull/42"}
             }}

          method == :patch and String.ends_with?(url, "/git/refs/heads/main") ->
            assert body["force"] == false

            {:ok,
             %Req.Response{status: 422, body: %{"message" => "Update is not a fast forward"}}}
        end
      end

      gh_pr_repo = %{
        id: "00000000-0000-4000-8000-000000000201",
        repo_url: "https://github.com/example/gitops",
        provider_type: :github,
        mode: :gitops_tree,
        branch: "main",
        base_path: "packs",
        push_strategy: :pull_request,
        credential_secret_id: "00000000-0000-4000-8000-000000000299"
      }

      assert {:ok, pushed} =
               GitOpsTreeClient.push_pack(gh_pr_repo, pack_v2,
                 token: "synthetic-pat",
                 http_json_client: github_mock
               )

      assert pushed.commit_sha == commit_sha
      assert pushed.pr_url == "https://github.com/example/gitops/pull/42"

      # Direct commit fails closed on concurrent upstream HEAD advancement without force-pushing
      gh_direct_repo = %{gh_pr_repo | push_strategy: :direct_commit}

      assert {:error, {:branch_conflict, %{"message" => "Update is not a fast forward"}}} =
               GitOpsTreeClient.push_pack(gh_direct_repo, pack_v2,
                 token: "synthetic-pat",
                 http_json_client: github_mock
               )

      # Staging / Prod dry-run pull preview + transactional apply recording source_commit_sha
      store = start_mem_store()

      assert {:ok, preview} =
               GitOpsTreeClient.preview_pull(gh_pr_repo, "wan-edge-sla",
                 actor: operator_actor(),
                 state_store: store,
                 token: "synthetic-pat",
                 http_json_client: github_mock
               )

      assert preview.dry_run == true
      assert preview.source_commit_sha == parent_sha
      assert Agent.get(store, & &1.packs) == %{}

      assert {:ok, applied} =
               GitOpsTreeClient.apply_pull(gh_pr_repo, "wan-edge-sla",
                 actor: operator_actor(),
                 state_store: store,
                 token: "synthetic-pat",
                 http_json_client: github_mock
               )

      assert applied.installed_pack.source_commit_sha == parent_sha
      assert applied.installed_pack.pack_version == "0.2.0"
    end

    test "pushes pack trees via GitLab Merge Request API and Gitea atomic contents batch API" do
      pack_v1 = build_test_pack("0.1.0", required_slot?: false)
      head_sha = String.duplicate("f0", 20)

      gitlab_mock = fn method, url, body, _opts ->
        cond do
          method == :get and String.contains?(url, "/repository/branches/main") ->
            {:ok, %Req.Response{status: 200, body: %{"commit" => %{"id" => head_sha}}}}

          method == :get and String.contains?(url, "/repository/tree") ->
            {:ok, %Req.Response{status: 200, body: []}}

          method == :post and String.ends_with?(url, "/repository/commits") ->
            assert body["last_commit_id"] == head_sha
            {:ok, %Req.Response{status: 201, body: %{"id" => String.duplicate("12", 20)}}}

          method == :post and String.ends_with?(url, "/merge_requests") ->
            {:ok,
             %Req.Response{
               status: 201,
               body: %{"web_url" => "https://gitlab.example.com/ops/packs/-/merge_requests/7"}
             }}
        end
      end

      gl_repo = %{
        id: "00000000-0000-4000-8000-000000000202",
        repo_url: "https://gitlab.example.com/ops/packs",
        provider_type: :gitlab,
        mode: :gitops_tree,
        branch: "main",
        base_path: "packs",
        push_strategy: :pull_request
      }

      assert {:ok, gl_res} =
               GitOpsTreeClient.push_pack(gl_repo, pack_v1,
                 token: "synthetic-gl-pat",
                 http_json_client: gitlab_mock
               )

      assert gl_res.pr_url == "https://gitlab.example.com/ops/packs/-/merge_requests/7"

      gitea_mock = fn method, url, _body, _opts ->
        cond do
          method == :get and String.ends_with?(url, "/branches/main") ->
            {:ok, %Req.Response{status: 200, body: %{"commit" => %{"id" => head_sha}}}}

          method == :get and String.contains?(url, "/git/trees/") ->
            {:ok, %Req.Response{status: 200, body: %{"tree" => []}}}

          method == :post and String.ends_with?(url, "/contents") ->
            {:ok,
             %Req.Response{
               status: 201,
               body: %{"commit" => %{"sha" => String.duplicate("34", 20)}}
             }}

          method == :post and String.ends_with?(url, "/pulls") ->
            {:ok,
             %Req.Response{
               status: 201,
               body: %{"html_url" => "https://gitea.example.com/ops/packs/pulls/3"}
             }}
        end
      end

      gitea_repo = %{
        id: "00000000-0000-4000-8000-000000000203",
        repo_url: "https://gitea.example.com/ops/packs",
        provider_type: :gitea,
        mode: :gitops_tree,
        branch: "main",
        base_path: "packs",
        push_strategy: :pull_request
      }

      assert {:ok, gitea_res} =
               GitOpsTreeClient.push_pack(gitea_repo, pack_v1,
                 token: "synthetic-gitea-pat",
                 http_json_client: gitea_mock
               )

      assert gitea_res.pr_url == "https://gitea.example.com/ops/packs/pulls/3"
    end

    test "aborts GitOps push before any HTTP request when SecretFreeValidator detects a secret" do
      pack_v1 = build_test_pack("0.1.0", required_slot?: false)
      leaked = Map.put(pack_v1, "README.md", "Token: ghp_" <> String.duplicate("z", 24))
      test_pid = self()

      never_called = fn _m, _u, _b, _o ->
        send(test_pid, :unexpected_network_call)
        {:error, :should_not_run}
      end

      repo = %{
        repo_url: "https://github.com/example/gitops",
        provider_type: :github,
        mode: :gitops_tree,
        branch: "main",
        base_path: "packs",
        push_strategy: :pull_request
      }

      assert {:error, _violations} =
               GitOpsTreeClient.push_pack(repo, leaked,
                 token: "synthetic-pat",
                 http_json_client: never_called
               )

      refute_receive :unexpected_network_call
    end
  end

  describe "CatalogSyncWorker per-repository fault isolation, RBAC, and OCSF audit redaction" do
    test "isolates failing repository while completing healthy release_catalog sync" do
      bad_repo = %{
        id: "00000000-0000-4000-8000-000000000301",
        repo_url: "https://developer.serviceradar.cloud/packs/broken.json",
        provider_type: :portal,
        mode: :release_catalog,
        enabled: true,
        credential_secret_id: nil
      }

      good_repo = %{
        id: "00000000-0000-4000-8000-000000000302",
        repo_url: "https://developer.serviceradar.cloud/packs/index.json",
        provider_type: :portal,
        mode: :release_catalog,
        enabled: true,
        credential_secret_id: nil
      }

      index_body =
        Jason.encode!(%{
          "packs" => [
            %{"id" => "io.serviceradar.storage-and-nvr-health", "version" => "0.2.0"}
          ]
        })

      fetcher = fn url, _opts ->
        if String.contains?(url, "broken.json") do
          {:error, {:http_status, 503}}
        else
          {:ok, %Req.Response{status: 200, body: index_body}}
        end
      end

      installed = [%{pack_id: "io.serviceradar.storage-and-nvr-health", pack_version: "0.1.0"}]
      test_pid = self()

      recorder = fn repo, status, payload ->
        send(test_pid, {:sync_recorded, repo.id, status, payload})
      end

      assert {:ok, [res1, res2]} =
               CatalogSyncWorker.sync_all_enabled(
                 repositories: [bad_repo, good_repo],
                 installed_packs: installed,
                 release_client_opts: [http_fetch_body: fetcher],
                 status_recorder: recorder
               )

      assert res1.status == :error
      assert res2.status == :ok

      assert res2.summary["updates_available"] == [
               %{
                 "pack_id" => "io.serviceradar.storage-and-nvr-health",
                 "available_version" => "0.2.0"
               }
             ]

      assert_receive {:sync_recorded, "00000000-0000-4000-8000-000000000301", :error, _}
      assert_receive {:sync_recorded, "00000000-0000-4000-8000-000000000302", :ok, _}
    end

    test "registers catalog RBAC permissions, guards built-in CatalogRepository changesets, and redacts OCSF audit details" do
      perm_keys =
        RBACCatalog.catalog()
        |> Enum.flat_map(& &1.permissions)
        |> MapSet.new(& &1.key)

      for key <- ~w(
            catalog.view
            catalog.packs.install
            catalog.packs.export
            catalog.repositories.manage
            catalog.gitops.sync
          ) do
        assert MapSet.member?(perm_keys, key)
      end

      sys_actor = SystemActor.system(:test)

      builtin = %CatalogRepository{
        id: "00000000-0000-4000-8000-000000000401",
        name: "ServiceRadar Official Solution Packs",
        mode: :release_catalog,
        provider_type: :github,
        repo_url: "https://github.com/carverauto/serviceradar",
        branch: "main",
        base_path: "packs",
        push_strategy: :pull_request,
        index_asset_name: "serviceradar-pack-index.json",
        signing_key_id: "serviceradar-first-party-v2",
        signing_public_key: Base.encode64(:binary.copy(<<0x44>>, 32)),
        builtin: true,
        is_default: true,
        enabled: true,
        credential_secret_id: "00000000-0000-4000-8000-000000000499"
      }

      edit_cs = Ash.Changeset.for_update(builtin, :update, %{name: "Tampered"}, actor: sys_actor)
      refute edit_cs.valid?
      assert Exception.message(Ash.Error.to_error_class(edit_cs.errors)) =~ "built-in"

      destroy_cs = Ash.Changeset.for_destroy(builtin, :destroy, %{}, actor: sys_actor)
      refute destroy_cs.valid?

      disable_cs = Ash.Changeset.for_update(builtin, :disable, %{}, actor: sys_actor)
      assert disable_cs.valid?

      repo_audit = CatalogNotifier.repository_audit_details(builtin)
      assert repo_audit.credential_attached == true
      refute Map.has_key?(repo_audit, :credential_secret_id)

      redacted =
        CatalogNotifier.sanitize_details(%{
          "repo_url" => "https://github.com/example/gitops",
          "commit_sha" => "deadbeef",
          "pat" => "secret-pat-value",
          "token" => "secret-token-value",
          "credential_secret_id" => "00000000-0000-4000-8000-000000000499"
        })

      assert redacted == %{
               "repo_url" => "https://github.com/example/gitops",
               "commit_sha" => "deadbeef"
             }

      repo_refs = PostgresInfo.references(CatalogRepository)

      assert Enum.any?(
               repo_refs,
               &(&1.relationship == :credential_secret and &1.on_delete == :restrict)
             )

      binding_refs = PostgresInfo.references(InstalledSolutionPackCredentialBinding)

      assert Enum.any?(
               binding_refs,
               &(&1.relationship == :credential_secret and &1.on_delete == :restrict)
             )

      assert Enum.any?(
               binding_refs,
               &(&1.relationship == :credential_rule and &1.on_delete == :restrict)
             )

      invalid_xor_cs =
        Ash.Changeset.for_create(
          InstalledSolutionPackCredentialBinding,
          :create,
          %{
            installed_pack_id: "00000000-0000-4000-8000-000000000501",
            slot: "target_http_api",
            credential_secret_id: "00000000-0000-4000-8000-000000000502",
            credential_rule_id: "00000000-0000-4000-8000-000000000503"
          },
          actor: sys_actor
        )

      refute invalid_xor_cs.valid?

      for resource <- [DeclarativeCheck, StatefulAlertRule, EventRule, ZenRule, AuthoredDashboard],
          attr <- [:pack_id, :pack_version, :managed, :template_fingerprint, :parameter_overrides] do
        assert ResourceInfo.attribute(resource, attr) != nil,
               "expected #{inspect(resource)} to define #{inspect(attr)}"
      end
    end
  end

  describe "v2 DependencyChecker, RBAC dashboard activation gate, and Uninstall/Detach" do
    test "DependencyChecker preserves list compat and checks worker + dashboard package dependencies" do
      # Legacy list signature
      assert {:ok, %{ready?: true, dependencies: []}} = DependencyChecker.check([])

      # Worker with fallback_runner is ready; required worker without fallback blocks
      manifest = %{
        "plugin_dependencies" => [],
        "worker_dependencies" => [
          %{
            "capability" => "vantage.alpr.v1",
            "min_protocol_version" => "vantage.worker.v1",
            "optional" => true,
            "fallback_runner" => "camera_vlm"
          },
          %{
            "capability" => "vantage.lpr-pro.v1",
            "min_protocol_version" => "vantage.worker.v2",
            "optional" => false
          }
        ],
        "dashboard_package_dependencies" => [
          %{
            "dashboard_id" => "com.serviceradar.test-console",
            "version_constraint" => ">= 1.0.0",
            "optional" => false
          }
        ]
      }

      assert {:ok, report_blocked} =
               DependencyChecker.check(manifest,
                 worker_registrations_loader: fn
                   "vantage.lpr-pro.v1" ->
                     [
                       %{
                         worker_id: "w1",
                         protocol_version: "vantage.worker.v1",
                         health: :ready,
                         capabilities: ["vantage.lpr-pro.v1"]
                       }
                     ]

                   _ ->
                     []
                 end,
                 dashboard_packages_loader: fn _id ->
                   [
                     %{
                       dashboard_id: "com.serviceradar.test-console",
                       version: "1.1.0",
                       status: :staged
                     }
                   ]
                 end
               )

      refute report_blocked.ready?
      assert report_blocked.blocking_count == 2
      [alpr_dep, lpr_dep] = report_blocked.worker_dependencies
      assert alpr_dep.status == :fallback_ready
      assert lpr_dep.status == :missing
      assert hd(report_blocked.dashboard_package_dependencies).status == :staged_approval_required

      assert {:ok, report_ready} =
               DependencyChecker.check(manifest,
                 worker_registrations_loader: fn
                   "vantage.lpr-pro.v1" ->
                     [
                       %{
                         worker_id: "w2",
                         protocol_version: "vantage.worker.v2",
                         health: :ready,
                         capabilities: ["vantage.lpr-pro.v1"]
                       }
                     ]

                   _ ->
                     []
                 end,
                 dashboard_packages_loader: fn _id ->
                   [
                     %{
                       dashboard_id: "com.serviceradar.test-console",
                       version: "1.1.0",
                       status: :enabled
                     }
                   ]
                 end
               )

      assert report_ready.ready?
      assert report_ready.blocking_count == 0
    end

    test "Reconciler enforces worker gate, RBAC + activation approval, version_already_published, and clean uninstall" do
      store = start_mem_store()
      blob_store = start_mem_blob_store()

      renderer_js = "export default function mountGateConsole(){ return 'SR-0100'; }"
      tree = build_v2_sample_pack(renderer_js)

      # 1. Missing required worker blocks active install unless install_paused: true
      blocked_worker_loader = fn _cap -> [] end

      assert {:error, {:unsatisfied_worker_dependencies, _}} =
               Reconciler.reconcile(tree, %{},
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: blocked_worker_loader
               )

      # 2. Requesting activate_dashboard_packages without dashboards.packages.* fails closed (Forbidden)
      online_worker_loader = fn cap ->
        [
          %{
            worker_id: "w-alpr",
            protocol_version: "vantage.worker.v1",
            health: :ready,
            capabilities: [cap]
          }
        ]
      end

      assert {:error, %Forbidden{}} =
               Reconciler.reconcile(tree, %{},
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      # 3. Default install (without activate_dashboard_packages) stages DashboardPackage + installs pipeline
      assert {:ok, staged_res} =
               Reconciler.reconcile(
                 tree,
                 %{"config" => %{"site_name" => "Gate West 01"}},
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader
               )

      assert hd(staged_res.applied_dashboard_packages).status == :staged
      assert Agent.get(store, &map_size(Map.get(&1, :dashboard_instances, %{}))) == 0
      assert Agent.get(store, &map_size(Map.get(&1, :vantage_pipelines, %{}))) == 1

      # 4. Authorized actor activating dashboard modules enables package and binds DashboardInstance with settings
      admin_actor = %{
        id: "00000000-0000-4000-8000-000000000010",
        email: "dash-admin@example.com",
        role: :admin,
        permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
      }

      assert {:ok, active_res} =
               Reconciler.reconcile(
                 tree,
                 %{"config" => %{"site_name" => "Gate West 01"}},
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      assert hd(active_res.applied_dashboard_packages).status == :enabled
      assert active_res.has_diverged? == false
      assert hd(active_res.vantage_pipelines).action == :unchanged
      assert hd(active_res.vantage_pipelines).diverged? == false
      inst = Agent.get(store, &get_in(&1, [:dashboard_instances, "vantage-gate-console"]))
      assert inst.enabled == true
      assert inst.settings == %{"site_name" => "Gate West 01"}

      # 5. version_already_published rejects differing renderer bytes for same version before blob write
      tampered_tree =
        build_v2_sample_pack("export default function tampered(){ return 'TEST-742'; }")

      assert {:error, {:version_already_published, _details}} =
               Reconciler.reconcile(tampered_tree, %{},
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      # 6. Uninstall removes managed resources and deletes blob while preserving managed: false resources
      assert {:ok, %{mode: :delete}} =
               Reconciler.uninstall("synthetic-v2-vantage",
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store
               )

      # Store pid so tests can inspect remaining blobs
      assert Agent.get(store, &get_in(&1, [:packs, "io.serviceradar.synthetic-v2-vantage"])) ==
               nil

      assert Agent.get(store, &map_size(Map.get(&1, :vantage_pipelines, %{}))) == 0
      assert Agent.get(store, &map_size(Map.get(&1, :dashboard_instances, %{}))) == 0
      assert Agent.get(store, &map_size(Map.get(&1, :dashboard_packages, %{}))) == 0
      assert Agent.get(Process.get(:mem_blob_agent), &map_size(&1)) == 0
    end

    test "upgrades v2 pack with $pack_param schemas, DashboardPackage bump, and :disabled status" do
      store = start_mem_store()
      blob_store = start_mem_blob_store()

      online_worker_loader = fn cap ->
        [
          %{
            worker_id: "w-alpr",
            protocol_version: "vantage.worker.v1",
            health: :ready,
            capabilities: [cap]
          }
        ]
      end

      admin_actor = %{
        id: "00000000-0000-4000-8000-000000000011",
        email: "dash-admin-upgrade@example.com",
        role: :admin,
        permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
      }

      v1_tree =
        build_v2_sample_pack(
          "export default function mountV1(){ return 'SR-0100'; }",
          pack_version: "1.0.0",
          dashboard_version: "1.0.0",
          paired_signal_schema?: true
        )

      assert {:ok, v1_res} =
               Reconciler.reconcile(
                 v1_tree,
                 %{"config" => %{"site_name" => "Gate West 01"}},
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      assert v1_res.has_diverged? == false
      assert hd(v1_res.vantage_pipelines).action == :create

      vp_v1 =
        Agent.get(
          store,
          &get_in(&1, [:vantage_pipelines, {"io.serviceradar.synthetic-v2-vantage.gate", "1.0.0"}])
        )

      assert vp_v1["camera_selector"] == %{"site" => "Gate West 01"}
      assert vp_v1["display_contract"]["title"] == "Gate West 01"
      assert vp_v1["signal_schema"]["description"] == "Gate West 01"

      # Re-reconcile identical v1 pack with empty params: must stay :unchanged (never :skipped_diverged)
      assert {:ok, re_res} =
               Reconciler.reconcile(
                 v1_tree,
                 %{},
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      assert re_res.has_diverged? == false
      assert hd(re_res.vantage_pipelines).diverged? == false
      assert hd(re_res.vantage_pipelines).action == :unchanged

      # Upgrade 1.0.0 -> 1.1.0: updates VantagePipeline + bumps DashboardPackage 1.0.0 -> 2.0.0 on SAME route_slug
      v1_1_tree =
        build_v2_sample_pack(
          "export default function mountV2(){ return 'TEST-742'; }",
          pack_version: "1.1.0",
          dashboard_version: "2.0.0",
          max_frames_per_track: 5,
          paired_signal_schema?: true
        )

      assert {:ok, v1_1_res} =
               Reconciler.reconcile(
                 v1_1_tree,
                 %{},
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      assert v1_1_res.has_diverged? == false
      assert hd(v1_1_res.vantage_pipelines).diverged? == false
      assert hd(v1_1_res.vantage_pipelines).action == :update

      vp_v1_1 =
        Agent.get(
          store,
          &get_in(&1, [:vantage_pipelines, {"io.serviceradar.synthetic-v2-vantage.gate", "1.0.0"}])
        )

      assert vp_v1_1["max_frames_per_track"] == 5
      assert vp_v1_1["camera_selector"] == %{"site" => "Gate West 01"}
      assert vp_v1_1["display_contract"]["title"] == "Gate West 01"
      assert vp_v1_1["signal_schema"]["description"] == "Gate West 01"

      # Upgraded DashboardInstance on same route_slug remains managed & bound to 2.0.0
      inst_v2 = Agent.get(store, &get_in(&1, [:dashboard_instances, "vantage-gate-console"]))
      assert inst_v2.managed == true
      assert inst_v2.pack_version == "1.1.0"
      assert inst_v2.dashboard_package.version == "2.0.0"

      # Old 1.0.0 DashboardPackage was detached (default orphan action)
      old_pkg =
        Agent.get(
          store,
          &get_in(&1, [:dashboard_packages, {"com.serviceradar.vantage-gate-console", "1.0.0"}])
        )

      assert old_pkg.managed == false

      # Upgrade 1.1.0 -> 1.2.0 with explicit :delete orphan decision for 2.0.0: preserves 3.0.0 instance!
      v1_2_tree =
        build_v2_sample_pack(
          "export default function mountV3(){ return 'TEST-742-V3'; }",
          pack_version: "1.2.0",
          dashboard_version: "3.0.0",
          max_frames_per_track: 6,
          paired_signal_schema?: true
        )

      assert {:ok, v1_2_res} =
               Reconciler.reconcile(
                 v1_2_tree,
                 %{
                   "decisions" => %{
                     "dashboard_package:com.serviceradar.vantage-gate-console:2.0.0" => "delete"
                   }
                 },
                 actor: admin_actor,
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: true
               )

      assert v1_2_res.has_diverged? == false

      inst_v3 = Agent.get(store, &get_in(&1, [:dashboard_instances, "vantage-gate-console"]))
      assert inst_v3.managed == true
      assert inst_v3.pack_version == "1.2.0"
      assert inst_v3.dashboard_package.version == "3.0.0"

      assert nil ==
               Agent.get(
                 store,
                 &get_in(
                   &1,
                   [:dashboard_packages, {"com.serviceradar.vantage-gate-console", "2.0.0"}]
                 )
               )

      # Disabled DashboardPackage stays :disabled when re-reconciling with activate_dashboard_packages: false
      Agent.update(store, fn st ->
        update_in(
          st,
          [:dashboard_packages, {"com.serviceradar.vantage-gate-console", "3.0.0"}],
          &Map.put(&1, :status, :disabled)
        )
      end)

      assert {:ok, disabled_res} =
               Reconciler.reconcile(
                 v1_2_tree,
                 %{},
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader,
                 activate_dashboard_packages: false
               )

      assert hd(disabled_res.applied_dashboard_packages).status == :disabled

      assert Agent.get(
               store,
               &get_in(
                 &1,
                 [:dashboard_packages, {"com.serviceradar.vantage-gate-console", "3.0.0"}]
               ).status
             ) == :disabled

      # Actual manual structural edit to persisted VantagePipeline MUST flag diverged? == true
      Agent.update(store, fn st ->
        put_in(
          st,
          [
            :vantage_pipelines,
            {"io.serviceradar.synthetic-v2-vantage.gate", "1.0.0"},
            "object_classes"
          ],
          ["bus"]
        )
      end)

      assert {:ok, div_res} =
               Reconciler.reconcile(
                 v1_2_tree,
                 %{},
                 actor: operator_actor(),
                 state_store: store,
                 dashboard_blob_store: blob_store,
                 worker_registrations_loader: online_worker_loader
               )

      assert div_res.has_diverged? == true
      assert hd(div_res.vantage_pipelines).diverged? == true
      assert hd(div_res.vantage_pipelines).action == :skipped_diverged
    end
  end

  defp start_mem_blob_store do
    {:ok, pid} = Agent.start_link(fn -> %{} end)

    then(
      %{
        put: fn key, bytes ->
          Agent.update(pid, &Map.put(&1, key, bytes))
          :ok
        end,
        delete: fn key ->
          Agent.update(pid, &Map.delete(&1, key))
          :ok
        end
      },
      fn callbacks ->
        Process.put(:mem_blob_agent, pid)
        callbacks
      end
    )
  end

  defp build_v2_sample_pack(renderer_js, opts \\ []) do
    pack_version = Keyword.get(opts, :pack_version, "1.0.0")
    dash_version = Keyword.get(opts, :dashboard_version, "1.0.0")
    max_frames = Keyword.get(opts, :max_frames_per_track)
    paired_schema? = Keyword.get(opts, :paired_signal_schema?, false)

    dash_manifest = %{
      "schema_version" => 1,
      "id" => "com.serviceradar.vantage-gate-console",
      "name" => "Vantage Gate Console",
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
          "pipeline_id" => "io.serviceradar.synthetic-v2-vantage.gate",
          "version" => "1.0.0",
          "name" => "Gate Plate Pipeline",
          "camera_selector" => %{"site" => %{"$pack_param" => "site_name"}},
          "signal_schema_id" => "gate_plate",
          "signal_schema_version" => "1.0.0",
          "display_contract_id" => "gate_plate"
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
          "schema_id" => "gate_plate",
          "version" => "1.0.0",
          "type" => "object",
          "description" => %{"$pack_param" => "site_name"},
          "properties" => %{"plate" => %{"type" => "string"}}
        }

        display_part = %{
          "display_contract_id" => "gate_plate",
          "title" => %{"$pack_param" => "site_name"}
        }

        entries = [
          %{
            "schema_id" => "gate_plate",
            "version" => "1.0.0",
            "schema_file" => "signal_schemas/gate_plate.schema.json",
            "display_file" => "signal_schemas/gate_plate.display.json"
          }
        ]

        files_map = %{
          "signal_schemas/gate_plate.schema.json" => Jason.encode!(schema_part),
          "signal_schemas/gate_plate.display.json" => Jason.encode!(display_part)
        }

        {entries, files_map}
      else
        schema_doc = %{
          "schema_id" => "gate_plate",
          "version" => "1.0.0",
          "schema" => %{"type" => "object", "properties" => %{"plate" => %{"type" => "string"}}},
          "display_contract" => %{"title" => "Gate Reads"}
        }

        entries = [
          %{
            "schema_id" => "gate_plate",
            "version" => "1.0.0",
            "file" => "signal_schemas/gate_plate.json"
          }
        ]

        {entries, %{"signal_schemas/gate_plate.json" => Jason.encode!(schema_doc)}}
      end

    manifest = %{
      "pack_format_version" => 2,
      "id" => "io.serviceradar.synthetic-v2-vantage",
      "slug" => "synthetic-v2-vantage",
      "name" => "Synthetic V2 Vantage",
      "version" => pack_version,
      "config" => [%{"key" => "site_name", "type" => "string", "default" => "Bay 04 Approach"}],
      "worker_dependencies" => [%{"capability" => "vantage.alpr.v1", "optional" => false}],
      "resources" => %{
        "checks" => [],
        "rules" => [],
        "dashboards" => [],
        "vantage_pipelines" => [
          %{
            "file" => "vantage_pipelines/gate.json",
            "pipeline_id" => "io.serviceradar.synthetic-v2-vantage.gate"
          }
        ],
        "signal_schemas" => schema_entries,
        "dashboard_packages" => [
          %{"slug" => "vantage-gate-console", "route_slug" => "vantage-gate-console"}
        ]
      },
      "files" => %{}
    }

    base_files =
      Map.merge(
        %{
          "README.md" => "# Synthetic V2\n",
          "vantage_pipelines/gate.json" => Jason.encode!(pipeline_doc),
          "dashboard_packages/vantage-gate-console/manifest.json" => Jason.encode!(dash_manifest),
          "dashboard_packages/vantage-gate-console/renderer.js" => renderer_js
        },
        schema_files
      )

    {:ok, _, files} = PackManifest.refresh_manifest_digests(manifest, base_files)

    files
  end
end
