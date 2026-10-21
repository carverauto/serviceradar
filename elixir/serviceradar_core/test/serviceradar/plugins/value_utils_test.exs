defmodule ServiceRadar.Plugins.ValueUtilsTest do
  use ExUnit.Case, async: true

  alias Ash.Notifier.Notification
  alias ServiceRadar.Events.AuditNotifier
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.PluginRepositoryNotifier
  alias ServiceRadar.Plugins.ValueUtils

  test "raw_value preserves false values" do
    assert ValueUtils.raw_value(%{enabled: false}, [:enabled, "enabled"]) == false
    assert ValueUtils.bool_value(%{enabled: false}, [:enabled, "enabled"], true) == false
  end

  describe "PluginRepositoryNotifier audit severity" do
    test "record_sync_error emits high-severity error audit events while routine actions stay informational" do
      record = %PluginRepository{
        id: "00000000-0000-0000-0000-000000000001",
        name: "ServiceRadar",
        repo_url: "https://github.com/example/serviceradar",
        artifact_kind: :wasm_plugin,
        index_asset_name: "serviceradar-wasm-plugin-index.json",
        signing_key_id: "serviceradar-first-party-v1",
        enabled: true,
        builtin: true,
        is_default: true,
        credential_secret_id: nil,
        last_sync_error: ":rate_limited"
      }

      error_notification = %Notification{
        resource: PluginRepository,
        data: record,
        action: %{name: :record_sync_error, type: :update},
        changeset: %{context: %{}}
      }

      assert PluginRepositoryNotifier.audit_severity(error_notification) == :high

      error_opts =
        AuditNotifier.build_opts(
          error_notification,
          PluginRepositoryNotifier.audit_opts(error_notification)
        )

      assert {:ok, error_event} = AuditWriter.build_event(error_opts)
      assert error_event.severity_id == OCSF.severity_high()
      assert error_event.severity == "High"
      assert error_event.log_level == "error"

      for action_name <- [:record_sync_success, :create, :update, :enable, :disable] do
        notification = %Notification{
          resource: PluginRepository,
          data: %{record | last_sync_error: nil},
          action: %{name: action_name, type: :update},
          changeset: %{context: %{}}
        }

        assert PluginRepositoryNotifier.audit_severity(notification) == :informational

        opts =
          AuditNotifier.build_opts(
            notification,
            PluginRepositoryNotifier.audit_opts(notification)
          )

        assert {:ok, event} = AuditWriter.build_event(opts)
        assert event.severity_id == OCSF.severity_informational()
        assert event.log_level == "info"
      end
    end
  end
end
