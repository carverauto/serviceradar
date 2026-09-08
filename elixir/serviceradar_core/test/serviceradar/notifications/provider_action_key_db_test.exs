defmodule ServiceRadar.Notifications.ProviderActionKeyDbTest do
  @moduledoc """
  A `:wasm_plugin` provider may only name a notifier its package ships
  (tasks 3.1.1b), and Phase 3 lifts the Phase 1 rule that rejected the tier
  outright (tasks 1.1.2a).

  This needs a database: the check resolves the referenced `PluginPackage` row
  and reads its stored manifest, so a fake changeset would prove nothing about
  the behaviour that matters.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_provider_action_key_test)}
  end

  # --- fixtures --------------------------------------------------------------

  defp notifier_manifest(plugin_id, keys) do
    %{
      "id" => plugin_id,
      "name" => "Acme Notifier",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "http_request", "notify:v1"],
      "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 5000},
      "notifications" =>
        Enum.map(keys, fn key ->
          %{
            "key" => key,
            "display_name" => "Acme #{key}",
            "entrypoint" => "notify_#{String.replace(key, "-", "_")}",
            "capabilities" => ["send", "test"],
            "payload_formats" => ["json"]
          }
        end)
    }
  end

  defp plain_manifest(plugin_id) do
    %{
      "id" => plugin_id,
      "name" => "Plain Checker",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log"],
      "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 5000}
    }
  end

  defp create_package!(manifest, actor) do
    plugin_id = manifest["id"]

    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: manifest["name"]},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: manifest["name"],
        version: manifest["version"],
        entrypoint: manifest["entrypoint"],
        runtime: manifest["runtime"],
        outputs: manifest["outputs"],
        manifest: manifest,
        content_hash: "sha256:#{plugin_id}-#{manifest["version"]}",
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp provider_attrs(overrides) do
    Map.merge(
      %{
        provider_key: "acme-#{System.unique_integer([:positive])}",
        provider_type: :wasm_plugin,
        display_name: "Acme Notifier",
        capabilities: [:send, :test],
        supported_routes: [:control_plane, :edge_agent],
        payload_formats: [:json]
      },
      overrides
    )
  end

  defp create_provider(attrs, actor) do
    NotificationProvider
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor)
  end

  defp action_key_errors({:error, %Ash.Error.Invalid{errors: errors}}) do
    errors
    |> Enum.filter(&(Map.get(&1, :field) == :action_key))
    |> Enum.map(&Exception.message/1)
  end

  # --- tests -----------------------------------------------------------------

  describe "Phase 3 admits the :wasm_plugin tier" do
    test "a provider bound to a declared notifier is created", %{actor: actor} do
      package =
        create_package!(notifier_manifest("acme-notifier-ok", ["pagerduty", "opsgenie"]), actor)

      assert {:ok, provider} =
               create_provider(
                 provider_attrs(%{plugin_package_id: package.id, action_key: "opsgenie"}),
                 actor
               )

      assert provider.provider_type == :wasm_plugin
      assert provider.action_key == "opsgenie"
      assert provider.plugin_package_id == package.id
      assert provider.status == :draft
    end

    test "the package foreign key restricts deletion while a provider uses it", %{actor: actor} do
      package = create_package!(notifier_manifest("acme-notifier-retained", ["pagerduty"]), actor)

      provider =
        %{plugin_package_id: package.id, action_key: "pagerduty"}
        |> provider_attrs()
        |> create_provider(actor)
        |> then(fn {:ok, provider} -> provider end)

      assert {:ok, %{rows: [["r"]]}} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 """
                 SELECT confdeltype::text
                   FROM pg_constraint
                  WHERE conname = 'notification_providers_plugin_package_id_fkey'
                 """,
                 []
               )

      assert {:error, _error} = Ash.destroy(package, actor: actor)

      assert Ash.get!(NotificationProvider, provider.id, actor: actor).plugin_package_id ==
               package.id
    end
  end

  describe "the action key must be declared" do
    test "an undeclared key is rejected and the message lists what is declared", %{actor: actor} do
      package =
        create_package!(notifier_manifest("acme-notifier-typo", ["pagerduty"]), actor)

      result =
        create_provider(
          provider_attrs(%{plugin_package_id: package.id, action_key: "pagerduy"}),
          actor
        )

      assert [message] = action_key_errors(result)
      assert message =~ "declares no notifier with this key"
      assert message =~ "pagerduty"
    end

    test "a package with no notifications block is rejected", %{actor: actor} do
      package = create_package!(plain_manifest("plain-checker"), actor)

      result =
        create_provider(
          provider_attrs(%{plugin_package_id: package.id, action_key: "pagerduty"}),
          actor
        )

      assert [message] = action_key_errors(result)
      assert message =~ "declares no notifications entries"
    end
  end

  describe "the shape rules Phase 1 already enforced still hold" do
    test "a :wasm_plugin provider without a package reference is rejected", %{actor: actor} do
      assert {:error, _error} =
               create_provider(provider_attrs(%{action_key: "pagerduty"}), actor)
    end

    test "a :native provider may not carry an action key", %{actor: actor} do
      package = create_package!(notifier_manifest("acme-notifier-native", ["pagerduty"]), actor)

      assert {:error, _error} =
               create_provider(
                 provider_attrs(%{
                   provider_type: :native,
                   implementation_module: "ServiceRadar.Notifications.Transports.Slack",
                   plugin_package_id: package.id,
                   action_key: "pagerduty"
                 }),
                 actor
               )
    end
  end
end
