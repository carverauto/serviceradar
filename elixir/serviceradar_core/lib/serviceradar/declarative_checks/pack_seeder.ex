defmodule ServiceRadar.DeclarativeChecks.PackSeeder do
  @moduledoc """
  Seeds and reconciles Built-in Solution Pack #1 (`io.serviceradar.storage-and-nvr-health`,
  PR #6760 control-plane posture checks, `2.3`) on coordinator startup.

  Uses `Importer.import_document/2` under a narrow system actor so:
  - Missing checks are created with `managed: true` and canonical `template_fingerprint`.
  - Managed checks whose semantic fingerprint matches their stored `template_fingerprint`
    are upgraded in place while preserving operator `parameter_overrides`, `ui_layout`,
    and `state`.
  - Operator-detached (`managed: false`) or diverged checks are left untouched.
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 8_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.AlertRuleSync
  alias ServiceRadar.DeclarativeChecks.BuiltinPacks
  alias ServiceRadar.DeclarativeChecks.CoreEvaluationWorker
  alias ServiceRadar.DeclarativeChecks.Importer

  require Logger

  @spec seed_all() :: :ok
  def seed_all do
    if repo_enabled?() do
      seed_builtin_packs()
    else
      :ok
    end
  end

  @doc """
  Idempotently imports and reconciles all built-in declarative check packs.
  """
  @spec seed_builtin_packs(keyword()) :: {:ok, [map()]}
  def seed_builtin_packs(opts \\ []) when is_list(opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:declarative_check_pack_seeder))

    results =
      Enum.map(BuiltinPacks.storage_and_nvr_checks(), fn doc ->
        seed_single_doc(doc, actor, opts)
      end)

    {:ok, results}
  end

  defp seed_single_doc(doc, actor, opts) do
    import_opts =
      opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put_new(:skip_srql_nif?, true)

    case Importer.import_document(doc, import_opts) do
      {:ok, %{check: check, action: action} = res} ->
        maybe_ensure_runtime(check, action)
        res

      {:error, reason} ->
        Logger.warning("failed to seed built-in declarative check",
          rule_name: Map.get(doc, "slug"),
          reason: inspect(reason)
        )

        %{action: :error, slug: Map.get(doc, "slug"), reason: reason}
    end
  end

  defp maybe_ensure_runtime(%{state: :enabled} = check, :unchanged) do
    _ = AlertRuleSync.reconcile(check)
    _ = CoreEvaluationWorker.ensure_scheduled(check)
    :ok
  end

  defp maybe_ensure_runtime(_check, _action), do: :ok
end
