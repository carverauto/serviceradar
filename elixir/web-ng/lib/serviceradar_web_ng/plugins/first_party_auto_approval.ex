defmodule ServiceRadarWebNG.Plugins.FirstPartyAutoApproval do
  @moduledoc """
  Decides whether a freshly imported first-party Wasm plugin package may be
  approved without an operator.

  A package qualifies only when all of these hold:

    * auto-approval is enabled (`:first_party_plugin_import`
      `:auto_approve_within_grant`, on by default);
    * it was imported from the built-in first-party repository. Packages from
      a third-party repository, an upload or a GitHub import never qualify;
    * its signature was verified on import;
    * the plugin already has an approved version, so the first approval of any
      plugin is always an operator's decision;
    * its requested capabilities, permissions and resources stay within the
      grant of the plugin's latest approved version (`GrantCeiling`).

  A qualifying package is approved with exactly the grant it requests, which
  is the prior grant narrowed to the request. Either way the decision is kept
  under `"auto_approval"` in the package's `source_metadata`, so a package
  left staged says which check held it and, for a widened grant, which fields
  widened.

  Approval only makes a version available. It does not rewrite an assignment.
  Tracking owners move later, on the rollout reconcile
  (`ServiceRadar.Plugins.WasmPluginRolloutArtifact`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Plugins.LatestApprovedPluginPackage
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.GrantCeiling
  alias ServiceRadarWebNG.Plugins.Repositories

  require Ash.Query

  @approved_by "system:first_party_auto_approval"
  @metadata_key "auto_approval"

  @type record :: %{String.t() => term()}
  @type decision :: {:approve, PluginPackage.t(), map()} | {:hold, record()}

  @doc "The actor every automatic approval and its bookkeeping runs as."
  @spec actor() :: map()
  def actor, do: SystemActor.system(:first_party_plugin_auto_approval)

  @doc "The `approved_by` stamped on an automatically approved package."
  @spec approved_by() :: String.t()
  def approved_by, do: @approved_by

  @doc "The `source_metadata` key that holds the decision record."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  Evaluates a staged package.

  Returns `{:approve, prior, approval_attrs}` when it qualifies, where `prior`
  is the approved version whose grant it stays within, or `{:hold, record}`
  with the decision record to keep on the package.
  """
  @spec evaluate(PluginPackage.t()) :: decision()
  def evaluate(%PluginPackage{} = package) do
    requested = requested_grant(package)

    with :ok <- enabled(),
         :ok <- first_party_source(package),
         :ok <- verified(package),
         {:ok, prior} <- prior_approved(package),
         :ok <- within_grant(requested, prior) do
      {:approve, prior, approval_attrs(requested)}
    else
      {:hold, reason, details} -> {:hold, record("held", reason, details)}
    end
  end

  @doc """
  The decision record for a package this module approved. A
  `post_approval_error` is the error a sync after the committed approval
  returned.
  """
  @spec approved_record(PluginPackage.t(), term()) :: record()
  def approved_record(%PluginPackage{} = prior, post_approval_error \\ nil) do
    details =
      prior
      |> prior_details()
      |> Map.merge(%{"automatic" => true, "approved_by" => @approved_by})

    details =
      if is_nil(post_approval_error),
        do: details,
        else: Map.put(details, "post_approval_error", inspect(post_approval_error))

    record("approved", "within_approved_grant", details)
  end

  @doc "The decision record for a qualifying package whose approval failed."
  @spec approval_failed_record(PluginPackage.t(), term()) :: record()
  def approval_failed_record(%PluginPackage{} = prior, reason) do
    record("held", "approval_failed", Map.put(prior_details(prior), "error", inspect(reason)))
  end

  @doc "Records the automatic approval of `package` in the audit trail."
  @spec audit(PluginPackage.t(), PluginPackage.t()) :: :ok
  def audit(%PluginPackage{} = package, %PluginPackage{} = prior) do
    AuditWriter.write_async(
      action: :auto_approve,
      resource_type: "plugin_package",
      resource_id: package.id,
      resource_name: "#{package.plugin_id}@#{package.version}",
      actor: actor(),
      message:
        "Plugin package #{package.plugin_id}@#{package.version} approved automatically " <>
          "within the grant approved for #{prior.version}",
      details: %{
        automatic: true,
        plugin_id: package.plugin_id,
        version: package.version,
        prior_package_id: prior.id,
        prior_version: prior.version,
        approved_by: @approved_by
      }
    )
  end

  defp enabled do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    if Keyword.get(config, :auto_approve_within_grant, true) do
      :ok
    else
      {:hold, "auto_approval_disabled", %{}}
    end
  end

  defp first_party_source(%PluginPackage{source_type: :first_party, source_repo_url: repo_url})
       when is_binary(repo_url) do
    case Repositories.get_by_repo_url(repo_url, actor: actor()) do
      {:ok, %{builtin: true}} -> :ok
      _other -> {:hold, "not_first_party", %{}}
    end
  end

  defp first_party_source(_package), do: {:hold, "not_first_party", %{}}

  defp verified(%PluginPackage{verification_status: "verified"}), do: :ok
  defp verified(_package), do: {:hold, "unverified", %{}}

  defp prior_approved(%PluginPackage{id: id, plugin_id: plugin_id}) do
    PluginPackage
    |> Ash.Query.for_read(:approved)
    |> Ash.Query.filter(plugin_id == ^plugin_id and id != ^id)
    |> Ash.read(actor: actor())
    |> case do
      {:ok, packages} ->
        case LatestApprovedPluginPackage.latest(packages) do
          nil -> {:hold, "first_version", %{}}
          prior -> {:ok, prior}
        end

      {:error, error} ->
        {:hold, "prior_lookup_failed", %{"error" => inspect(error)}}
    end
  end

  defp within_grant(requested, prior) do
    case GrantCeiling.widenings(requested, AgentConfigGenerator.package_grant(prior)) do
      [] -> :ok
      widened -> {:hold, "grant_widened", Map.put(prior_details(prior), "widened", widened)}
    end
  end

  # What the manifest asks for, ignoring any approval fields a re-staged
  # package may still carry from an earlier review.
  defp requested_grant(package) do
    AgentConfigGenerator.package_grant(%{
      package
      | approved_capabilities: [],
        approved_permissions: %{},
        approved_resources: %{}
    })
  end

  defp approval_attrs(requested) do
    %{
      approved_capabilities: requested.capabilities,
      approved_permissions: stringify_keys(requested.permissions),
      approved_resources: stringify_keys(requested.resources)
    }
  end

  defp prior_details(%PluginPackage{} = prior) do
    %{"prior_package_id" => prior.id, "prior_version" => prior.version}
  end

  defp record(decision, reason, details) do
    Map.merge(
      %{
        "decision" => decision,
        "reason" => reason,
        "evaluated_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      details
    )
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
