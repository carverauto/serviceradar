defmodule ServiceRadar.Plugins.DisplayContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.DisplayContract

  @repo_root Path.expand("../../../../..", __DIR__)

  @first_party_contracts [
    "addons/anomaly-addon/display/detection_finding.display.json",
    "addons/powerdns/display/dns_activity.display.json",
    "go/cmd/wasm-plugins/axis/display/event_log_activity.display.json",
    "go/cmd/wasm-plugins/unifi-protect/display/camera_event.display.json",
    "go/cmd/wasm-plugins/proxmox/display/resource_event.display.json",
    "go/pkg/trivysidecar/display/vulnerability_report.display.json",
    "integrations/falco/display/runtime_event.display.json"
  ]

  @packaged_contracts [
    %{
      manifest: "addons/anomaly-addon/addon.yaml",
      contract: "addons/anomaly-addon/display/detection_finding.display.json",
      producer_id: "anomaly",
      producer_version: "0.3.6"
    },
    %{
      manifest: "addons/powerdns/addon.yaml",
      contract: "addons/powerdns/display/dns_activity.display.json",
      producer_id: "powerdns",
      producer_version: "0.1.7"
    },
    %{
      manifest: "go/cmd/wasm-plugins/axis/plugin.yaml",
      contract: "go/cmd/wasm-plugins/axis/display/event_log_activity.display.json",
      producer_id: "axis-camera",
      producer_version: "0.1.3"
    },
    %{
      manifest: "go/cmd/wasm-plugins/proxmox/plugin.yaml",
      contract: "go/cmd/wasm-plugins/proxmox/display/resource_event.display.json",
      producer_id: "proxmox-inventory",
      producer_version: "0.1.8"
    },
    %{
      manifest: "go/cmd/wasm-plugins/unifi-protect/plugin.yaml",
      contract: "go/cmd/wasm-plugins/unifi-protect/display/camera_event.display.json",
      producer_id: "unifi-protect-camera",
      producer_version: "0.1.4"
    }
  ]

  @valid %{
    "id" => "com.example.thing.display",
    "version" => "1.0.0",
    "schema_id" => "com.example.thing",
    "schema_version" => "2.1.0",
    "widgets" => [
      %{"type" => "summary", "title" => "query.hostname", "message" => "message"},
      %{"type" => "facts", "fields" => [%{"label" => "Domain", "path" => "query.hostname"}]}
    ]
  }

  describe "the contracts shipping today" do
    # If this ever fails, the validator has become stricter than what first-party
    # packages already ship, and the events and logs pages lose their contracts.
    test "every first-party display contract validates" do
      for relative <- @first_party_contracts do
        path = Path.join(@repo_root, relative)
        assert File.exists?(path), "missing first-party contract fixture: #{relative}"

        assert {:ok, contract} = DisplayContract.validate(File.read!(path)),
               "#{relative} was rejected by the validator"

        assert contract["surface"] == "signal"
        assert contract["widgets"] != []
      end
    end

    test "timestamp-aware contracts ship as revision 1.1 without changing their payload schema" do
      for relative <- @first_party_contracts do
        contract = @repo_root |> Path.join(relative) |> File.read!() |> Jason.decode!()

        assert contract["version"] == "1.1.0", "#{relative} did not bump its document revision"
        assert contract["schema_version"] == "1.0.0", "#{relative} changed its payload schema"
      end
    end

    test "package manifests bind their exact producer and display contract revisions" do
      for binding <- @packaged_contracts do
        manifest_path = Path.join(@repo_root, binding.manifest)
        manifest = manifest_path |> File.read!() |> YamlElixir.read_from_string!()
        contract = @repo_root |> Path.join(binding.contract) |> File.read!() |> Jason.decode!()

        relative_contract = Path.relative_to(binding.contract, Path.dirname(binding.manifest))

        signal =
          Enum.find(manifest["signal_schemas"], &(&1["display_contract"] == relative_contract))

        assert manifest["id"] == binding.producer_id
        assert manifest["version"] == binding.producer_version
        assert %{} = signal, "#{binding.manifest} does not declare #{relative_contract}"
        assert signal["id"] == contract["schema_id"]
        assert signal["version"] == contract["schema_version"]
        assert signal["display_contract_id"] == contract["id"]
        assert signal["display_contract_version"] == contract["version"]
      end
    end
  end

  describe "validate/1" do
    test "normalizes a valid contract and defaults the surface" do
      assert {:ok, contract} = DisplayContract.validate(@valid)
      assert contract["surface"] == "signal"
      assert DisplayContract.key(contract) == "com.example.thing.display@1.0.0"
      assert DisplayContract.signal_binding(contract) == {"com.example.thing", "2.1.0"}
    end

    test "normalizes explicit timestamp and unix-nanosecond field formats" do
      contract =
        Map.put(@valid, "widgets", [
          %{
            "type" => "timeline",
            "fields" => [
              %{"label" => "Event time", "path" => "time", "format" => "timestamp"},
              %{"label" => "Observed", "path" => "observed", "format" => "unix_nano"}
            ]
          }
        ])

      assert {:ok, normalized} = DisplayContract.validate(contract)

      assert get_in(normalized, ["widgets", Access.at(0), "fields", Access.at(0), "format"]) ==
               "timestamp"

      assert get_in(normalized, ["widgets", Access.at(0), "fields", Access.at(1), "format"]) ==
               "unix_nano"
    end

    test "rejects unknown temporal formats" do
      contract =
        Map.put(@valid, "widgets", [
          %{
            "type" => "facts",
            "fields" => [%{"label" => "When", "path" => "time", "format" => "guess"}]
          }
        ])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "format must be one of timestamp, unix_nano"))
    end

    test "accepts a JSON string as well as a decoded map" do
      assert {:ok, contract} = DisplayContract.validate(Jason.encode!(@valid))
      assert DisplayContract.key(contract) == "com.example.thing.display@1.0.0"
    end

    test "a non-signal surface has no signal binding" do
      contract = Map.put(@valid, "surface", "notification_delivery")

      assert {:ok, normalized} = DisplayContract.validate(contract)
      assert normalized["surface"] == "notification_delivery"
      assert DisplayContract.signal_binding(normalized) == nil
    end

    test "rejects an unknown surface" do
      assert {:error, errors} = DisplayContract.validate(Map.put(@valid, "surface", "anything"))
      assert Enum.any?(errors, &(&1 =~ "surface must be one of"))
    end

    test "rejects an unknown top-level key rather than ignoring it" do
      assert {:error, errors} = DisplayContract.validate(Map.put(@valid, "widget", []))
      assert Enum.any?(errors, &(&1 =~ "display contract.widget is not allowed"))
    end

    test "rejects an unknown widget type" do
      contract = Map.put(@valid, "widgets", [%{"type" => "producer_html"}])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "widgets[0].type must be one of"))
    end

    test "rejects an unknown widget key" do
      contract =
        Map.put(@valid, "widgets", [
          %{"type" => "summary", "title" => "message", "template" => "x"}
        ])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "widgets[0].template is not allowed"))
    end

    # The manifest validator hard-rejects these nine on an `actions:` entry. A
    # display contract must not be a second door into the same capability.
    test "rejects every UI-code key the manifest already refuses" do
      for key <- DisplayContract.forbidden_keys() do
        contract = Map.put(@valid, key, "<script>alert(1)</script>")

        assert {:error, errors} = DisplayContract.validate(contract),
               "#{key} was accepted at the top level"

        assert Enum.any?(errors, &(&1 =~ "#{key} is not allowed"))
      end
    end

    test "rejects a UI-code key buried at any depth" do
      contract =
        Map.put(@valid, "widgets", [
          %{
            "type" => "facts",
            "fields" => [%{"label" => "X", "path" => "a.b", "component" => "Evil"}]
          }
        ])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "component is not allowed"))
    end

    test "rejects a non-semver version" do
      assert {:error, errors} = DisplayContract.validate(Map.put(@valid, "version", "one"))
      assert Enum.any?(errors, &(&1 =~ "version must be a valid semver string"))
    end

    test "rejects an id that is not a lowercase slug" do
      assert {:error, errors} = DisplayContract.validate(Map.put(@valid, "id", "Com.Example"))
      assert Enum.any?(errors, &(&1 =~ "id must use lowercase"))
    end

    test "rejects a path that is not a plain dotted key walk" do
      contract =
        Map.put(@valid, "widgets", [
          %{"type" => "facts", "fields" => [%{"label" => "X", "path" => "query..bad"}]}
        ])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "path must be a valid path"))
    end

    test "rejects a contract with no widgets" do
      assert {:error, errors} = DisplayContract.validate(Map.put(@valid, "widgets", []))
      assert Enum.any?(errors, &(&1 =~ "at least one widget"))
    end

    test "rejects more widgets than the renderer will draw" do
      widget = %{"type" => "summary", "title" => "message"}
      contract = Map.put(@valid, "widgets", List.duplicate(widget, 25))

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "more than 24 widgets"))
    end

    test "rejects a table column list that is not a list of label/path pairs" do
      contract =
        Map.put(@valid, "widgets", [
          %{"type" => "table", "path" => "rows", "columns" => [%{"label" => "X"}]}
        ])

      assert {:error, errors} = DisplayContract.validate(contract)
      assert Enum.any?(errors, &(&1 =~ "columns[0].path must be a valid path"))
    end

    test "rejects a non-object document" do
      assert {:error, ["display contract must be a JSON object"]} = DisplayContract.validate([])
    end
  end

  describe "validate_all/1" do
    test "keys contracts by id and version" do
      other =
        @valid
        |> Map.put("id", "com.example.other.display")
        |> Map.put("schema_id", "com.example.other")

      assert {:ok, contracts} =
               DisplayContract.validate_all(%{
                 "display/a.json" => @valid,
                 "display/b.json" => other
               })

      assert contracts |> Map.keys() |> Enum.sort() == [
               "com.example.other.display@1.0.0",
               "com.example.thing.display@1.0.0"
             ]
    end

    test "rejects two documents that resolve to the same key" do
      assert {:error, errors} =
               DisplayContract.validate_all(%{
                 "display/a.json" => @valid,
                 "display/b.json" => @valid
               })

      assert Enum.any?(errors, &(&1 =~ "is declared more than once"))
    end

    test "names the source of a rejected document" do
      assert {:error, errors} =
               DisplayContract.validate_all(%{"display/bad.json" => Map.delete(@valid, "id")})

      assert Enum.any?(errors, &(&1 =~ "display/bad.json:"))
    end

    test "an absent block is not an error" do
      assert {:ok, %{}} = DisplayContract.validate_all(nil)
      assert {:ok, %{}} = DisplayContract.validate_all(%{})
    end
  end
end
