defmodule ServiceRadar.Plugins.PluginUpdatePolicy do
  @moduledoc """
  Update policy of a Wasm plugin assignment owner.

  An owner is a manual `PluginAssignment` or a `PluginTargetPolicy`. Its
  `update_policy` is either:

  * `:track_latest_approved` - the owner follows the latest approved package with
    the same `plugin_id` (see `ServiceRadar.Plugins.LatestApprovedPluginPackage`).
  * `:pinned` - the owner keeps its selected package until an operator changes it.

  `update_policy_source` records who chose the value: `:operator` for anything a
  person or a caller set, `:migration_default` for rows that existed when the
  column was introduced. Only `:migration_default` rows may be changed by
  `ServiceRadar.Plugins.PluginUpdatePolicyBackfillWorker`.

  A new owner defaults by package provenance: a trusted first-party package
  tracks the latest approved version, anything else is pinned.

  Credential-rule owners always follow the latest approved package and carry no
  column of their own. Policy-materialized assignment rows (`source: :policy`)
  follow their owner, so their own `update_policy` is not consulted.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginRepository

  require Ash.Query

  @type t :: :track_latest_approved | :pinned

  @doc """
  The update policy a new owner of `package` defaults to.
  """
  @spec default_for(PluginPackage.t() | nil) :: t()
  def default_for(%PluginPackage{} = package) do
    if trusted_first_party?(package), do: :track_latest_approved, else: :pinned
  end

  def default_for(_package), do: :pinned

  @doc """
  Whether `package` is a signed, verified first-party package.

  `source_type: :first_party` alone is not enough: every catalog repository,
  including third-party ones, imports through the first-party path. The package
  must also come from a built-in Wasm plugin repository, the deployment's
  first-party trust anchor. `PluginUpdatePolicyBackfillWorker` applies the same
  conditions in SQL.
  """
  @spec trusted_first_party?(PluginPackage.t()) :: boolean()
  def trusted_first_party?(%PluginPackage{} = package) do
    package.source_type == :first_party and package.verification_status == "verified" and
      is_nil(package.verification_error) and signed?(package.signature) and
      builtin_repository?(package.source_repo_url)
  end

  defp signed?(signature), do: is_map(signature) and map_size(signature) > 0

  defp builtin_repository?(repo_url) when is_binary(repo_url) and repo_url != "" do
    PluginRepository
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      builtin == true and artifact_kind == :wasm_plugin and repo_url == ^repo_url
    )
    |> Ash.exists?(actor: SystemActor.system(:plugin_update_policy))
  end

  defp builtin_repository?(_repo_url), do: false
end
