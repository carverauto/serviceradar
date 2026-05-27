defmodule ServiceRadar.Inventory.VisibilityProfileSrqlTargetResolver do
  @moduledoc """
  Resolves visibility profile targeting using SRQL queries.

  Blank visibility profile targets are treated as `in:devices`, matching
  the operator-facing default scope from the host-network-visibility spec.
  """

  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLProfileResolver

  require Ash.Query

  @default_target_query "in:devices"

  @spec resolve_for_device(String.t() | nil, map()) ::
          {:ok, VisibilityProfile.t() | nil} | {:error, term()}
  def resolve_for_device(device_uid, actor) when is_binary(device_uid) do
    SRQLProfileResolver.resolve(device_uid, actor,
      load_profiles: &load_targeting_profiles/1,
      match_profile: &matches_device?/3,
      log_prefix: "VisibilitySrqlTargetResolver"
    )
  end

  def resolve_for_device(nil, _actor), do: {:ok, nil}

  @spec target_query_for_match(VisibilityProfile.t()) :: String.t()
  def target_query_for_match(%VisibilityProfile{target_query: target_query}) do
    case target_query do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: @default_target_query, else: trimmed

      _ ->
        @default_target_query
    end
  end

  defp load_targeting_profiles(actor) do
    query = Ash.Query.for_read(VisibilityProfile, :list_targeting_profiles, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} -> {:ok, profiles}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matches_device?(profile, device_uid, actor) do
    combined_query = "#{target_query_for_match(profile)} uid:\"#{device_uid}\""

    with {:ok, ast} <- SRQLAst.parse(combined_query) do
      SRQLDeviceMatcher.match_ast(ast, actor, log_prefix: "VisibilitySrqlTargetResolver")
    end
  end
end
