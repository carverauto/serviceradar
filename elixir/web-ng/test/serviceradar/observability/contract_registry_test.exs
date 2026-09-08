defmodule ServiceRadarWebNG.Observability.ContractRegistryTest do
  # Not async: the runtime-resolution cases replace a process-wide ETS index and
  # an application environment key.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Observability.SignalDisplay

  @moduletag :db_free

  @repo_root Path.expand("../../../../..", __DIR__)

  @third_party_contract %{
    "id" => "com.thirdparty.widgetworks.alarm.display",
    "version" => "1.0.0",
    "schema_id" => "com.thirdparty.widgetworks.alarm",
    "schema_version" => "1.0.0",
    "widgets" => [
      %{"type" => "summary", "title" => "alarm.name", "message" => "message"},
      %{
        "type" => "facts",
        "fields" => [
          %{"label" => "Zone", "path" => "alarm.zone"},
          %{"label" => "Panel", "path" => "alarm.panel"}
        ]
      }
    ]
  }

  @delivery_contract %{
    "id" => "com.thirdparty.widgetworks.receipt.display",
    "version" => "1.0.0",
    "schema_id" => "widgetworks_pager",
    "schema_version" => "1.0.0",
    "surface" => "notification_delivery",
    "widgets" => [
      %{"type" => "facts", "fields" => [%{"label" => "Ticket", "path" => "ticket_id"}]}
    ]
  }

  @package %{
    id: "11111111-1111-1111-1111-111111111111",
    plugin_id: "widgetworks",
    version: "3.2.1",
    display_contracts: %{
      "com.thirdparty.widgetworks.alarm.display@1.0.0" => @third_party_contract,
      "com.thirdparty.widgetworks.receipt.display@1.0.0" => @delivery_contract
    },
    manifest: %{
      "id" => "widgetworks",
      "name" => "WidgetWorks",
      "version" => "3.2.1",
      "entrypoint" => "run",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["log", "http_request", "notify:v1"],
      "resources" => %{"requested_memory_mb" => 16},
      "notifications" => [
        %{
          "key" => "widgetworks_pager",
          "display_name" => "WidgetWorks Pager",
          "entrypoint" => "notify_pager",
          "capabilities" => ["send", "test"],
          "payload_formats" => ["json"],
          "config_schema" => %{
            "type" => "object",
            "properties" => %{"routing_key" => %{"type" => "string"}}
          }
        }
      ]
    }
  }

  @third_party_event %{
    "message" => "Zone 4 alarm",
    "alarm" => %{"name" => "Front door", "zone" => "4", "panel" => "north"},
    "metadata" => %{
      "service_radar" => %{
        "signal_schema" => %{
          "producer_id" => "widgetworks",
          "producer_version" => "3.2.1",
          "schema_id" => "com.thirdparty.widgetworks.alarm",
          "schema_version" => "1.0.0"
        }
      }
    }
  }

  @first_party_packages [
    %{
      manifest: "addons/anomaly-addon/addon.yaml",
      package_key: :addon_id,
      ref: %{
        "producer_id" => "anomaly",
        "producer_version" => "0.3.6",
        "schema_id" => "com.carverauto.anomaly.detection_finding",
        "schema_version" => "1.0.0"
      }
    },
    %{
      manifest: "addons/powerdns/addon.yaml",
      package_key: :addon_id,
      ref: %{
        "producer_id" => "powerdns",
        "producer_version" => "0.1.7",
        "schema_id" => "com.carverauto.powerdns.dns_activity",
        "schema_version" => "1.0.0"
      }
    },
    %{
      manifest: "go/cmd/wasm-plugins/axis/plugin.yaml",
      package_key: :plugin_id,
      ref: %{
        "producer_id" => "axis-camera",
        "producer_version" => "0.1.3",
        "schema_id" => "com.carverauto.axis_camera.event_log",
        "schema_version" => "1.0.0"
      }
    },
    %{
      manifest: "go/cmd/wasm-plugins/proxmox/plugin.yaml",
      package_key: :plugin_id,
      ref: %{
        "producer_id" => "proxmox-inventory",
        "producer_version" => "0.1.8",
        "schema_id" => "com.carverauto.proxmox.resource_event",
        "schema_version" => "1.0.0"
      }
    },
    %{
      manifest: "go/cmd/wasm-plugins/unifi-protect/plugin.yaml",
      package_key: :plugin_id,
      ref: %{
        "producer_id" => "unifi-protect-camera",
        "producer_version" => "0.1.4",
        "schema_id" => "com.carverauto.unifi_protect.camera_event",
        "schema_version" => "1.0.0"
      }
    }
  ]

  describe "index/1" do
    test "indexes a signal contract under the four-part schema ref" do
      {entries, diagnostics} = ContractRegistry.index([@package])

      assert diagnostics == []

      assert {_key, contract} =
               Enum.find(entries, fn
                 {{:signal, "widgetworks", "3.2.1", "com.thirdparty.widgetworks.alarm", "1.0.0"}, _contract} ->
                   true

                 _entry ->
                   false
               end)

      assert contract["id"] == "com.thirdparty.widgetworks.alarm.display"
    end

    test "indexes a non-signal contract under its surface and notifier key" do
      {entries, _diagnostics} = ContractRegistry.index([@package])

      assert Enum.any?(entries, fn
               {{:surface, "widgetworks", "3.2.1", "notification_delivery", "widgetworks_pager"}, _contract} ->
                 true

               _entry ->
                 false
             end)
    end

    test "indexes the validated notifications block by package id and notifier key" do
      {entries, _diagnostics} = ContractRegistry.index([@package])

      assert {_key, entry} =
               Enum.find(entries, fn
                 {{:notifier, _package_id, "widgetworks_pager"}, _entry} -> true
                 _entry -> false
               end)

      assert entry["config_schema"]["properties"]["routing_key"]["type"] == "string"
    end

    test "maps a package id to its producer identity" do
      {entries, _diagnostics} = ContractRegistry.index([@package])

      assert Enum.any?(entries, fn
               {{:package, id}, {"widgetworks", "3.2.1"}} -> id == @package.id
               _entry -> false
             end)
    end

    # A contract stored by an older release is re-validated on the way out, so a
    # rule added later is enforced against rows that predate it.
    test "a stored contract that no longer validates is a diagnostic, not an entry" do
      broken =
        put_in(@package.display_contracts, %{
          "com.thirdparty.widgetworks.alarm.display@1.0.0" => Map.put(@third_party_contract, "html", "<script>")
        })

      {entries, diagnostics} = ContractRegistry.index([broken])

      refute Enum.any?(entries, &match?({{:signal, _, _, _, _}, _}, &1))

      assert [%{package: "widgetworks", version: "3.2.1"} = diagnostic] = diagnostics
      assert diagnostic.reason =~ "html is not allowed"
    end

    test "a package with no id or version contributes nothing" do
      assert {[], []} = ContractRegistry.index([%{id: "x", plugin_id: nil, version: nil}])
    end

    test "an add-on package is keyed by its addon_id" do
      addon =
        @package
        |> Map.delete(:plugin_id)
        |> Map.put(:addon_id, "widgetworks-addon")

      {entries, _diagnostics} = ContractRegistry.index([addon])

      assert Enum.any?(entries, fn
               {{:package, _id}, {"widgetworks-addon", "3.2.1"}} -> true
               _entry -> false
             end)
    end
  end

  describe "runtime resolution" do
    setup do
      # Under `SERVICERADAR_ALLOW_DB_FREE_TESTS` the application tree is not
      # started, so the registry this suite exercises has to be started here.
      # Under a database run the application already owns it.
      if is_nil(Process.whereis(ContractRegistry)) do
        start_supervised!({ContractRegistry, []})
      end

      original = Application.get_env(:serviceradar_web_ng, ContractRegistry)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:serviceradar_web_ng, ContractRegistry)
          config -> Application.put_env(:serviceradar_web_ng, ContractRegistry, config)
        end

        ContractRegistry.refresh()
      end)

      :ok
    end

    defp install(packages) do
      Application.put_env(:serviceradar_web_ng, ContractRegistry, packages: packages)
      :ok = ContractRegistry.refresh()
    end

    # THE point of tasks 3.5.1. This package is not in `@built_in_contracts` and
    # nothing about it was compiled into web-ng, yet its signal renders.
    test "a third-party package's contract renders with no web-ng recompile" do
      install([@package])

      assert {:ok, contract, :runtime} =
               SignalDisplay.resolve_contract_with_source(@third_party_event)

      assert contract["id"] == "com.thirdparty.widgetworks.alarm.display"

      assert {:ok, widgets} = SignalDisplay.render_record(@third_party_event)
      assert [%{type: :summary} = summary, %{type: :facts} = facts] = widgets
      assert summary.title == "Front door"
      assert summary.message == "Zone 4 alarm"
      assert %{value: "4"} = Enum.find(facts.fields, &(&1.label == "Zone"))
    end

    test "shipped first-party producer refs resolve their exact package contracts at runtime" do
      packages = Enum.map(@first_party_packages, &first_party_package/1)
      install(packages)

      for {spec, package} <- Enum.zip(@first_party_packages, packages) do
        event = event_with_signal_ref(spec.ref)

        assert package.version == spec.ref["producer_version"]

        assert {:ok, contract, :runtime} =
                 SignalDisplay.resolve_contract_with_source(event),
               "#{spec.ref["producer_id"]} did not resolve through its installed package"

        assert contract["version"] == "1.1.0"
      end
    end

    test "a producer-version mismatch cannot reach another package revision" do
      anomaly = Enum.find(@first_party_packages, &(&1.ref["producer_id"] == "anomaly"))
      install([first_party_package(anomaly)])

      mismatched_ref = Map.put(anomaly.ref, "producer_version", "0.3.5")

      assert :error =
               ContractRegistry.lookup_signal(
                 mismatched_ref["producer_id"],
                 mismatched_ref["producer_version"],
                 mismatched_ref["schema_id"],
                 mismatched_ref["schema_version"]
               )

      assert :error =
               mismatched_ref
               |> event_with_signal_ref()
               |> SignalDisplay.resolve_contract_with_source()
    end

    test "the same signal renders nothing once its package is uninstalled" do
      install([@package])
      assert {:ok, _widgets} = SignalDisplay.render_record(@third_party_event)

      install([])
      assert :error = SignalDisplay.render_record(@third_party_event)
    end

    # The compile-time first-party map is the FALLBACK, not the removed layer:
    # first-party contracts are not shipped inside their add-on bundles, so a
    # package-first resolution that dropped it would stop PowerDNS rendering.
    test "a first-party signal still resolves from the built-in map" do
      install([])

      event = %{
        "message" => "RPZ blocked suspicious.example",
        "query" => %{"hostname" => "suspicious.example"},
        "metadata" => %{
          "service_radar" => %{
            "signal_schema" => %{
              "producer_id" => "powerdns",
              "producer_version" => "0.1.1",
              "schema_id" => "com.carverauto.powerdns.dns_activity",
              "schema_version" => "1.0.0"
            }
          }
        }
      }

      assert {:ok, _contract, :built_in} = SignalDisplay.resolve_contract_with_source(event)
      assert {:ok, [%{type: :summary} = summary | _rest]} = SignalDisplay.render_record(event)
      assert summary.title == "suspicious.example"
    end

    test "an installed package overrides nothing it did not declare" do
      install([@package])

      other = put_in(@third_party_event, ["metadata", "service_radar", "signal_schema", "producer_version"], "9.9.9")

      assert :error = SignalDisplay.resolve_contract_with_source(other)
    end

    test "diagnostics are enumerable for a contract this node refused" do
      broken =
        put_in(@package.display_contracts, %{
          "com.thirdparty.widgetworks.alarm.display@1.0.0" => Map.put(@third_party_contract, "live_view", "Evil")
        })

      install([broken])

      assert [%{package: "widgetworks", reason: reason}] = ContractRegistry.diagnostics()
      assert reason =~ "live_view is not allowed"

      # The broken contract degrades to no contract, not to a crash.
      assert :error = SignalDisplay.render_record(@third_party_event)
    end

    test "notifier and surface lookups are served from the index" do
      install([@package])

      assert {:ok, entry} = ContractRegistry.lookup_notifier(@package.id, "widgetworks_pager")
      assert entry["display_name"] == "WidgetWorks Pager"

      assert {:ok, {"widgetworks", "3.2.1"}} = ContractRegistry.package_identity(@package.id)

      assert {:ok, contract} =
               ContractRegistry.lookup_surface(
                 "widgetworks",
                 "3.2.1",
                 "notification_delivery",
                 "widgetworks_pager"
               )

      assert contract["id"] == "com.thirdparty.widgetworks.receipt.display"
      assert :error = ContractRegistry.lookup_notifier(@package.id, "not_declared")
      assert :error = ContractRegistry.lookup_notifier(nil, "widgetworks_pager")
    end

    test "loaded_at advances on refresh" do
      install([@package])
      assert %DateTime{} = ContractRegistry.loaded_at()
    end
  end

  defp first_party_package(spec) do
    manifest_path = Path.join(@repo_root, spec.manifest)
    manifest = manifest_path |> File.read!() |> YamlElixir.read_from_string!()
    signal = Enum.find(manifest["signal_schemas"], &(&1["id"] == spec.ref["schema_id"]))
    contract_path = Path.join(Path.dirname(manifest_path), signal["display_contract"])
    contract = contract_path |> File.read!() |> Jason.decode!()

    Map.put(
      %{
        id: "fixture-#{manifest["id"]}",
        version: manifest["version"],
        display_contracts: %{"#{contract["id"]}@#{contract["version"]}" => contract},
        signal_schemas: manifest["signal_schemas"],
        manifest: manifest
      },
      spec.package_key,
      manifest["id"]
    )
  end

  defp event_with_signal_ref(ref) do
    %{"metadata" => %{"service_radar" => %{"signal_schema" => ref}}}
  end
end
