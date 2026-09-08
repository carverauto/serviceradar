defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.ContractsTest do
  # Not async: installs a process-wide runtime contract index.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Contracts

  @moduletag :db_free

  @package_id "22222222-2222-2222-2222-222222222222"

  @delivery_contract %{
    "id" => "com.thirdparty.pagerworks.receipt.display",
    "version" => "1.0.0",
    "schema_id" => "pagerworks",
    "schema_version" => "1.0.0",
    "surface" => "notification_delivery",
    "widgets" => [
      %{
        "type" => "facts",
        "fields" => [
          %{"label" => "Ticket", "path" => "ticket_id"},
          %{"label" => "Assignee", "path" => "assignee.name"}
        ]
      }
    ]
  }

  @health_contract %{
    "id" => "com.thirdparty.pagerworks.health.display",
    "version" => "1.0.0",
    "schema_id" => "pagerworks",
    "schema_version" => "1.0.0",
    "surface" => "notification_channel_health",
    "widgets" => [
      %{"type" => "facts", "fields" => [%{"label" => "Last error", "path" => "last_error"}]}
    ]
  }

  @package %{
    id: @package_id,
    plugin_id: "pagerworks",
    version: "1.4.0",
    display_contracts: %{
      "com.thirdparty.pagerworks.receipt.display@1.0.0" => @delivery_contract,
      "com.thirdparty.pagerworks.health.display@1.0.0" => @health_contract
    },
    manifest: %{
      "id" => "pagerworks",
      "name" => "PagerWorks",
      "version" => "1.4.0",
      "entrypoint" => "run",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["log", "notify:v1"],
      "resources" => %{"requested_memory_mb" => 16},
      "notifications" => [
        %{
          "key" => "pagerworks",
          "display_name" => "PagerWorks",
          "entrypoint" => "notify",
          "capabilities" => ["send", "test"],
          "payload_formats" => ["json"],
          "config_schema" => %{
            "type" => "object",
            "properties" => %{
              "routing_key" => %{"type" => "string", "secretRef" => true},
              "queue" => %{"type" => "string"}
            }
          }
        }
      ]
    }
  }

  @plugin_provider %{
    provider_type: :wasm_plugin,
    plugin_package_id: @package_id,
    action_key: "pagerworks",
    # Deliberately STALE: the point of runtime resolution is that the manifest
    # wins over the copy taken when the provider row was created.
    config_schema: %{"type" => "object", "properties" => %{"old_field" => %{"type" => "string"}}}
  }

  @native_provider %{
    provider_type: :native,
    plugin_package_id: nil,
    action_key: nil,
    config_schema: %{"type" => "object", "properties" => %{"webhook_url" => %{"type" => "string"}}}
  }

  setup do
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

  describe "config_contract/1" do
    test "a plugin provider's form comes from the package manifest, not the stored copy" do
      install([@package])

      assert %{source: :package, schema: schema, diagnostics: []} =
               Contracts.config_contract(@plugin_provider)

      assert schema["properties"] |> Map.keys() |> Enum.sort() == ["queue", "routing_key"]
      refute Map.has_key?(schema["properties"], "old_field")
    end

    test "a plugin provider whose package is not indexed falls back with a diagnostic" do
      install([])

      assert %{source: :provider, schema: schema, diagnostics: [diagnostic]} =
               Contracts.config_contract(@plugin_provider)

      assert schema == @plugin_provider.config_schema
      assert diagnostic =~ "not in the runtime contract index"
    end

    test "a non-plugin provider uses its stored schema with no diagnostic" do
      install([@package])

      assert %{source: :provider, schema: schema, diagnostics: []} =
               Contracts.config_contract(@native_provider)

      assert schema == @native_provider.config_schema
    end

    test "no provider selected yields an empty schema rather than an error" do
      assert %{source: :none, schema: %{}, diagnostics: []} = Contracts.config_contract(nil)
    end

    # The stored schema is what secret-field detection and the test-send payload
    # read; resolving them from a different schema than the form rendered would
    # classify a package-declared secret as ordinary configuration.
    test "config_schema/1 returns the same schema the form renders" do
      install([@package])

      assert Contracts.config_schema(@plugin_provider) ==
               Contracts.config_contract(@plugin_provider).schema
    end
  end

  describe "delivery_view/2" do
    test "renders the package's notification_delivery contract when one is installed" do
      install([@package])

      summary = %{"ticket_id" => "INC-42", "assignee" => %{"name" => "on-call"}}

      assert %{source: :contract, widgets: [%{type: :facts, fields: fields}], diagnostics: []} =
               Contracts.delivery_view(summary, @plugin_provider)

      assert %{value: "INC-42"} = Enum.find(fields, &(&1.label == "Ticket"))
      assert %{value: "on-call"} = Enum.find(fields, &(&1.label == "Assignee"))
    end

    test "degrades to the generic view when the package ships no contract" do
      install([])

      assert %{source: :generic, widgets: widgets} =
               Contracts.delivery_view(%{"status" => "sent"}, @plugin_provider)

      assert [%{type: :facts, fields: [%{label: "Status", value: "sent"}]}] = widgets
    end

    test "an empty or missing result summary renders nothing at all" do
      install([@package])

      assert %{widgets: []} = Contracts.delivery_view(%{}, @plugin_provider)
      assert %{widgets: []} = Contracts.delivery_view(nil, @plugin_provider)
    end
  end

  describe "channel_health_view/2" do
    test "renders the package's channel-health contract" do
      install([@package])

      channel = %{health: :failing, last_error: "connection refused", last_success_at: nil}

      assert %{source: :contract, widgets: [%{type: :facts, fields: fields}]} =
               Contracts.channel_health_view(channel, @plugin_provider)

      assert [%{label: "Last error", value: "connection refused"}] = fields
    end

    test "degrades to the generic view with no contract, and survives no channel" do
      install([])

      channel = %{health: :degraded, last_error: "timeout"}

      assert %{source: :generic, widgets: [%{type: :facts, fields: fields}]} =
               Contracts.channel_health_view(channel, @native_provider)

      assert fields |> Enum.map(& &1.label) |> Enum.sort() == ["Health", "Last Error"]
      assert %{widgets: []} = Contracts.channel_health_view(nil, @native_provider)
    end
  end

  describe "registry_diagnostics/0" do
    test "surfaces a contract this node refused" do
      broken =
        put_in(@package.display_contracts, %{
          "com.thirdparty.pagerworks.receipt.display@1.0.0" => Map.put(@delivery_contract, "react", "Evil")
        })

      install([broken])

      assert [%{package: "pagerworks", reason: reason}] = Contracts.registry_diagnostics()
      assert reason =~ "react is not allowed"
    end
  end
end
