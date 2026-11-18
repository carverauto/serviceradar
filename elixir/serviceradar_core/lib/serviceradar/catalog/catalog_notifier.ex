defmodule ServiceRadar.Catalog.CatalogNotifier do
  @moduledoc """
  Writes redacted OCSF audit records (`class_uid: 1008`) via
  `ServiceRadar.Events.AuditWriter` for catalog repository mutations, solution
  pack installations, upgrades, uninstalls, exports, and GitOps push/pull syncs.

  Attached credentials and PATs are never included in audit payloads: repository
  records emit `credential_attached` as a boolean only, and imperative sync/export
  operations strip secret-bearing keys before publishing.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Events.AuditNotifier
  alias ServiceRadar.Events.AuditWriter

  @redacted_detail_keys ~w(
    token
    api_token
    access_token
    github_token
    pat
    password
    secret
    secret_payload
    encrypted_secret_payload
    private_key
    authorization
    credential_secret_id
    credential_rule_id
  )

  @impl Ash.Notifier
  def notify(%Notification{resource: CatalogRepository} = notification) do
    AuditNotifier.write_async(notification, repository_audit_opts(notification))
    :ok
  end

  def notify(%Notification{resource: InstalledSolutionPack} = notification) do
    AuditNotifier.write_async(notification, installed_pack_audit_opts(notification))
    :ok
  end

  def notify(_notification), do: :ok

  @doc """
  Builds `AuditNotifier` options for a `CatalogRepository` notification.
  """
  @spec repository_audit_opts(Notification.t()) :: keyword()
  def repository_audit_opts(%Notification{data: record} = notification) do
    [
      resource_type: "catalog_repository",
      resource_id: record.id,
      resource_name: record.name,
      severity: repository_severity(notification),
      details: repository_audit_details(record)
    ]
  end

  @doc """
  Builds `AuditNotifier` options for an `InstalledSolutionPack` notification.
  """
  @spec installed_pack_audit_opts(Notification.t()) :: keyword()
  def installed_pack_audit_opts(%Notification{data: record}) do
    [
      resource_type: "installed_solution_pack",
      resource_id: record.id,
      resource_name: record.pack_id,
      severity: :informational,
      details: installed_pack_audit_details(record)
    ]
  end

  @doc """
  Maps repository actions to OCSF audit severity.
  """
  @spec repository_severity(Notification.t() | atom()) :: AuditWriter.severity()
  def repository_severity(%Notification{action: %{name: action_name}}),
    do: repository_severity(action_name)

  def repository_severity(:record_sync_error), do: :high
  def repository_severity(_action), do: :informational

  @doc """
  Redacted detail map recorded for a `CatalogRepository` mutation.
  """
  @spec repository_audit_details(struct()) :: map()
  def repository_audit_details(record) do
    %{
      mode: record.mode,
      provider_type: record.provider_type,
      repo_url: record.repo_url,
      branch: record.branch,
      base_path: record.base_path,
      push_strategy: record.push_strategy,
      index_asset_name: record.index_asset_name,
      signing_key_id: record.signing_key_id,
      enabled: record.enabled,
      auto_reconcile: record.auto_reconcile,
      builtin: record.builtin,
      is_default: record.is_default,
      credential_attached: not is_nil(record.credential_secret_id)
    }
  end

  @doc """
  Redacted detail map recorded for an `InstalledSolutionPack` mutation.
  """
  @spec installed_pack_audit_details(struct()) :: map()
  def installed_pack_audit_details(record) do
    %{
      pack_id: record.pack_id,
      slug: record.slug,
      pack_version: record.pack_version,
      source_type: record.source_type,
      catalog_repository_id: record.catalog_repository_id,
      source_commit_sha: record.source_commit_sha,
      source_release_tag: record.source_release_tag,
      source_branch: record.source_branch,
      source_pr_url: record.source_pr_url
    }
  end

  @doc """
  Writes a redacted OCSF audit event for an imperative catalog operation
  (`:pack_export`, `:gitops_push`, `:gitops_pull`, `:release_catalog_import`).
  """
  @spec write_operation_audit(atom(), keyword()) :: :ok
  def write_operation_audit(action, opts) when is_atom(action) and is_list(opts) do
    details =
      opts
      |> Keyword.get(:details, %{})
      |> sanitize_details()

    audit_opts = [
      action: action,
      resource_type: Keyword.get(opts, :resource_type, "solution_pack"),
      resource_id: Keyword.get(opts, :resource_id, "unknown"),
      resource_name: Keyword.get(opts, :resource_name),
      actor: Keyword.get(opts, :actor),
      severity: Keyword.get(opts, :severity, :informational),
      message: Keyword.get(opts, :message),
      details: details
    ]

    AuditWriter.write_async(audit_opts)
  end

  @doc """
  Recursively strips secret-bearing keys from an audit details map.
  """
  @spec sanitize_details(term()) :: term()
  def sanitize_details(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key_str = k |> to_string() |> String.downcase()

      if key_str in @redacted_detail_keys do
        acc
      else
        Map.put(acc, k, sanitize_details(v))
      end
    end)
  end

  def sanitize_details(list) when is_list(list), do: Enum.map(list, &sanitize_details/1)
  def sanitize_details(other), do: other
end
