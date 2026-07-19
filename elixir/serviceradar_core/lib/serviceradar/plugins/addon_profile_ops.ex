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

    with {:ok, %AddonProfile{} = profile} <- AddonProfile.get_by_id(id, actor: actor),
         {:ok, profile} <- Ash.load(profile, :addon_package, actor: actor) do
      AddonProfileReconciler.preview(profile, opts)
    end
  end

  @spec reconcile_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_by_id(id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_profile_reconcile_now))

    with {:ok, %AddonProfile{} = profile} <- AddonProfile.get_by_id(id, actor: actor),
         {:ok, profile} <- Ash.load(profile, :addon_package, actor: actor) do
      case AddonProfileReconciler.reconcile(profile, opts) do
        {:ok, result} ->
          persisted_result = Map.put(result, :status, "succeeded")

          with {:ok, _updated} <- update_profile_summary(profile, persisted_result, actor) do
            {:ok, result}
          end

        {:error, error} = failure ->
          _ = update_profile_summary(profile, failure_summary(error), actor)
          failure
      end
    end
  end

  defp update_profile_summary(profile, result, actor) do
    attrs = %{
      last_reconciled_at: DateTime.utc_now(),
      last_reconcile_summary: result
    }

    profile
    |> Ash.Changeset.for_update(:record_reconcile_result, attrs)
    |> Ash.update(actor: actor)
  end

  defp failure_summary(error) do
    errors = normalize_errors(error)

    # Pin every count the UI card reads to 0 AND carry a non-nil `last_error`
    # (plus `status: "failed"`) so a FAILED reconcile is visually distinguishable
    # from a genuine empty match. Without matched_rows/eligible_agents here the
    # card defaults both to 0 and renders identically to a 0/0/0 success.
    %{
      status: "failed",
      errors: errors,
      last_error: List.first(errors) || "reconcile failed",
      matched_rows: 0,
      eligible_agents: 0,
      desired_assignments: 0,
      upserted: 0,
      unchanged: 0,
      disabled: 0
    }
  end

  defp normalize_errors(errors) when is_list(errors) do
    errors
    |> Enum.take(5)
    |> Enum.map(&format_error/1)
  end

  defp normalize_errors(error), do: [format_error(error)]

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error, limit: 8, printable_limit: 400)
end
