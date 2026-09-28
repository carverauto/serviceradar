defmodule ServiceRadar.Repo.Migrations.CreateStatefulEvaluationLedger do
  @moduledoc """
  Records which OCSF events have had their alert consequences applied (stateful
  rule evaluation and promotion alerts), so a JetStream redelivery evaluates an
  event only if its first delivery did not finish. Control-plane bookkeeping:
  it holds event ids, not events, and is pruned after three days.
  """
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:stateful_evaluation_ledger, primary_key: false, prefix: @prefix) do
      add :event_id, :uuid, null: false, primary_key: true

      add :evaluated_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create index(:stateful_evaluation_ledger, [:evaluated_at], prefix: @prefix)
  end
end
