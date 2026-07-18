defmodule ServiceRadarWebNG.Plugins.AddonRollouts do
  @moduledoc "Scoped operator access to native add-on fleet rollouts."

  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator

  require Ash.Query

  @spec list(keyword()) :: [AddonRollout.t()]
  def list(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(100)
    |> Ash.Query.load([:previous_package, :candidate_package, :targets])
    |> read(scope)
  rescue
    _ -> []
  end

  def pause(id, opts \\ []), do: transition(:pause, id, opts)
  def resume(id, opts \\ []), do: transition(:resume, id, opts)
  def cancel(id, opts \\ []), do: transition(:cancel, id, opts)
  def rollback(id, opts \\ []), do: transition(:rollback, id, opts)

  defp transition(action, id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || scope_actor(scope)
    apply(AddonRolloutCoordinator, action, [id, [actor: actor]])
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil
end
