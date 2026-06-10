defmodule ServiceRadar.Plugins.AddonProfileOps do
  @moduledoc """
  Operations for add-on profiles: preview and immediate reconciliation.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileReconciler

  require Ash.Query

  @spec preview_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_by_id(id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_profile_preview))

    with {:ok, %AddonProfile{} = profile} <- AddonProfile.get_by_id(id, actor: actor) do
      AddonProfileReconciler.preview(profile, opts)
    end
  end

  @spec reconcile_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_by_id(id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_profile_reconcile_now))

    with {:ok, %AddonProfile{} = profile} <- AddonProfile.get_by_id(id, actor: actor),
         {:ok, result} <- AddonProfileReconciler.reconcile(profile, opts),
         {:ok, _updated} <- update_profile_summary(profile, result, actor) do
      {:ok, result}
    end
  end

  defp update_profile_summary(profile, result, actor) do
    attrs = %{
      last_reconciled_at: DateTime.utc_now(),
      last_reconcile_summary: result
    }

    profile
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end
end
