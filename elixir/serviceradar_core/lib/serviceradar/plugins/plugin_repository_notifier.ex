defmodule ServiceRadar.Plugins.PluginRepositoryNotifier do
  @moduledoc """
  Writes an OCSF audit record for every plugin repository change.

  Adding a repository is a trust decision -- it declares a new source whose
  signing key the platform will accept packages against -- so it needs a record
  of who did it, not just the resulting row. Enable and disable are audited for
  the same reason: disabling the built-in source silently stops first-party
  imports, and "why did the catalog go empty" should be answerable.

  The attached credential is referenced by id only. The PAT never reaches an
  audit record, which is the point of keeping it in the credential store rather
  than on this row.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Events.AuditNotifier
  alias ServiceRadar.Events.AuditWriter

  @impl Ash.Notifier
  def notify(%Notification{resource: ServiceRadar.Plugins.PluginRepository} = notification) do
    AuditNotifier.write_async(notification, audit_opts(notification))

    :ok
  end

  def notify(_notification), do: :ok

  @doc """
  Builds the `AuditNotifier` options for a plugin repository notification.
  """
  @spec audit_opts(Notification.t()) :: keyword()
  def audit_opts(%Notification{data: record} = notification) do
    [
      resource_type: "plugin_repository",
      resource_id: record.id,
      resource_name: record.name,
      severity: audit_severity(notification),
      details: audit_details(record)
    ]
  end

  @doc """
  Maps plugin repository actions to their OCSF audit severity.

  Recording a sync failure is an operational error on a trust source and is
  logged at `:high` (`log_level: "error"`); routine configuration and
  sync-success transitions remain `:informational`.
  """
  @spec audit_severity(Notification.t() | atom()) :: AuditWriter.severity()
  def audit_severity(%Notification{action: %{name: action_name}}), do: audit_severity(action_name)
  def audit_severity(:record_sync_error), do: :high
  def audit_severity(_action), do: :informational

  @doc """
  The details recorded for a repository change.

  Public so the "no credential material reaches the audit log" property can be
  asserted directly, rather than by reconstructing the whole notifier ->
  AuditWriter -> InternalLogPublisher pipeline in a test. `credential_attached`
  is deliberately a boolean: the audit trail should record that a repository has
  a token, never which one or what it is.
  """
  @spec audit_details(struct()) :: map()
  def audit_details(record) do
    %{
      repo_url: record.repo_url,
      artifact_kind: record.artifact_kind,
      index_asset_name: record.index_asset_name,
      # The key id identifies which trust anchor is in play; the public key is
      # not a secret but is noise in an audit trail.
      signing_key_id: record.signing_key_id,
      enabled: record.enabled,
      builtin: record.builtin,
      is_default: record.is_default,
      credential_attached: not is_nil(record.credential_secret_id)
    }
  end
end
