defmodule ServiceRadar.Observability.AlertEvaluationReceipt do
  @moduledoc """
  Durable completion or audited terminal disposition of accepted alert input.

  A receipt is committed in the same owner transaction as snapshots, alerts,
  history and outbox work. Its identity follows the source occurrence and rule,
  independently of batch boundaries. Retention must cover the supported source
  replay horizon; JetStream's short duplicate window is not that horizon.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Repo

  require Ash.Query

  postgres do
    table "alert_evaluation_receipts"
    repo Repo
    schema "platform"

    custom_indexes do
      index [:completed_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [:rule_id, :source_key, :position, :disposition, :details, :resolved_count]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    uuid_primary_key :id
    attribute :rule_id, :uuid, allow_nil?: false
    attribute :source_key, :string, allow_nil?: false, constraints: [max_length: 256]
    attribute :position, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :disposition, :atom do
      allow_nil? false
      constraints one_of: [:completed, :cancelled, :failed]
    end

    attribute :details, :map, allow_nil?: false, default: %{}
    attribute :resolved_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    create_timestamp :completed_at
  end

  identities do
    identity :rule_source, [:rule_id, :source_key]
  end

  # Admission's replay lookup and retention cannot race one another.
  @doc "Prunes a bounded page beyond the configured source replay horizon. Pending work is never pruned."
  def prune(now \\ DateTime.utc_now()) do
    retention_days = Application.get_env(:serviceradar_core, :alert_evaluation_receipt_days, 7)

    if retention_valid?() do
      cutoff = DateTime.shift(now, day: -retention_days)

      Inbox.transact(2_000, fn ->
        Inbox.lock_admission()
        prune_owned(cutoff)
      end)
    else
      {:error, :invalid_alert_receipt_retention}
    end
  end

  @doc "Whether receipt retention covers the configured source replay horizon."
  def retention_valid? do
    replay = Application.get_env(:serviceradar_core, :alert_evaluation_replay_days, 7)
    retention = Application.get_env(:serviceradar_core, :alert_evaluation_receipt_days, 7)
    is_integer(replay) and replay > 0 and is_integer(retention) and retention >= replay
  end

  defp prune_owned(cutoff) do
    ids =
      __MODULE__
      |> Ash.Query.filter(completed_at < ^cutoff)
      |> Ash.Query.sort(completed_at: :asc)
      |> Ash.Query.limit(10_000)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: Inbox.actor())
      |> Enum.map(& &1.id)

    __MODULE__
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy(:destroy, %{},
      actor: Inbox.actor(),
      strategy: [:atomic],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> Repo.rollback({:receipt_prune_failed, errors})
    end
  end
end
