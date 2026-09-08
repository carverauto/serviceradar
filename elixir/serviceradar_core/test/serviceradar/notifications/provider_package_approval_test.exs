defmodule ServiceRadar.Notifications.ProviderPackageApprovalTest do
  @moduledoc """
  A notification provider is bound to an APPROVED plugin package, and stops
  being usable when that approval is withdrawn (tasks 3.3.2).

  Revoking a package is a security action: it says "stop running this code". A
  provider bound to it is a live route from an alert to that code, so three
  things have to hold and they fail at different times:

    * a provider on an unapproved package cannot be ACTIVATED;
    * an already-active provider is DEACTIVATED when the package is revoked;
    * `:disable` is never blocked - turning off a provider whose package was
      revoked is the correct response to the revocation, and a validation that
      blocked it would trap exactly the rows an operator needs to clean up.

  The fourth guarantee, that dispatch refuses regardless, is
  `ServiceRadar.Notifications.PluginTargetTest`'s: a notifier is a signal, not a
  guarantee, so the enforcing check reads the package status at dispatch.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.PackageApprovalWatcher
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_provider_approval_test)}
  end

  describe "activation" do
    test "a provider on an approved package activates", %{actor: actor} do
      package = actor |> create_package!() |> approve!(actor)
      provider = create_provider!(package, actor)

      assert {:ok, activated} = activate(provider, actor)
      assert activated.status == :active
    end

    test "a provider on a staged package cannot activate", %{actor: actor} do
      package = create_package!(actor)
      provider = create_provider!(package, actor)

      assert {:error, error} = activate(provider, actor)
      assert Exception.message(error) =~ "only an approved package"
      assert reload!(provider, actor).status == :draft
    end

    test "a provider on a revoked package cannot be re-activated", %{actor: actor} do
      package = actor |> create_package!() |> approve!(actor)
      provider = package |> create_provider!(actor) |> activate!(actor)

      revoke!(package, actor)

      assert {:error, _error} = activate(reload!(provider, actor), actor)
    end

    test "a :native provider is unaffected", %{actor: actor} do
      # The rule is about the plugin reference, not about providers in general.
      provider =
        NotificationProvider
        |> Ash.Changeset.for_create(
          :create,
          %{
            provider_key: "native-#{System.unique_integer([:positive])}",
            provider_type: :native,
            display_name: "Native",
            capabilities: [:send, :test],
            supported_routes: [:control_plane],
            payload_formats: [:json],
            implementation_module: "ServiceRadar.Notifications.Transports.GenericWebhook"
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      assert {:ok, %{status: :active}} = activate(provider, actor)
    end
  end

  describe "revocation" do
    test "deactivates every provider bound to the package", %{actor: actor} do
      package = actor |> create_package!() |> approve!(actor)
      first = package |> create_provider!(actor) |> activate!(actor)
      second = package |> create_provider!(actor) |> activate!(actor)

      revoke!(package, actor)

      assert reload!(first, actor).status == :disabled
      assert reload!(second, actor).status == :disabled
    end

    test "leaves providers on other packages alone", %{actor: actor} do
      revoked = actor |> create_package!() |> approve!(actor)
      kept = actor |> create_package!() |> approve!(actor)

      doomed = revoked |> create_provider!(actor) |> activate!(actor)
      survivor = kept |> create_provider!(actor) |> activate!(actor)

      revoke!(revoked, actor)

      assert reload!(doomed, actor).status == :disabled
      assert reload!(survivor, actor).status == :active
    end

    test "is idempotent and reportable outside a revocation", %{actor: actor} do
      package = actor |> create_package!() |> approve!(actor)
      provider = package |> create_provider!(actor) |> activate!(actor)

      assert [id] = PackageApprovalWatcher.disable_providers_for_package(package.id, actor: actor)
      assert id == provider.id

      # A second pass finds nothing left to do rather than erroring on a row
      # that is already disabled.
      assert PackageApprovalWatcher.disable_providers_for_package(package.id, actor: actor) == []
    end
  end

  describe "disable is never blocked" do
    test "a provider on a revoked package can still be disabled", %{actor: actor} do
      package = actor |> create_package!() |> approve!(actor)
      # Left `:draft`, so the watcher's own `:disable` does not get there first
      # and what is exercised is the validation's absence from `:disable`
      # rather than the state machine's refusal to re-disable.
      provider = create_provider!(package, actor)

      revoke!(package, actor)

      assert {:ok, %{status: :disabled}} =
               provider
               |> reload!(actor)
               |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
               |> Ash.update(actor: actor)
    end
  end

  # --- fixtures --------------------------------------------------------------

  defp create_package!(actor) do
    plugin_id = "acme-notifier-#{System.unique_integer([:positive])}"

    manifest = %{
      "id" => plugin_id,
      "name" => "Acme Notifier",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "http_request", "notify:v1"],
      "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 5000},
      "notifications" => [
        %{
          "key" => "pagerduty",
          "display_name" => "Acme PagerDuty",
          "entrypoint" => "notify_pagerduty",
          "capabilities" => ["send", "test"],
          "payload_formats" => ["json"]
        }
      ]
    }

    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Acme Notifier"},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Acme Notifier",
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        content_hash: "sha256:#{plugin_id}",
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp approve!(package, actor) do
    package
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: ["get_config", "log", "http_request", "notify:v1"]},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp revoke!(package, actor) do
    package
    |> Ash.Changeset.for_update(:revoke, %{denied_reason: "signature no longer trusted"},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp create_provider!(package, actor) do
    NotificationProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_key: "acme-#{System.unique_integer([:positive])}",
        provider_type: :wasm_plugin,
        display_name: "Acme Notifier",
        capabilities: [:send, :test],
        supported_routes: [:control_plane, :edge_agent],
        payload_formats: [:json],
        plugin_package_id: package.id,
        action_key: "pagerduty"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp activate(provider, actor) do
    provider
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp activate!(provider, actor) do
    {:ok, activated} = activate(provider, actor)
    activated
  end

  defp reload!(provider, actor) do
    NotificationProvider
    |> Ash.Query.for_read(:by_id, %{id: provider.id})
    |> Ash.read_one!(actor: actor)
  end
end
