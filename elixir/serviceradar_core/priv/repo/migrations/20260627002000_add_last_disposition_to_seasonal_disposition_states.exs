defmodule ServiceRadar.Repo.Migrations.AddLastDispositionToSeasonalDispositionStates do
  @moduledoc """
  Records the latest central-seasonal evaluation outcome per persisted state row.
  """
  use Ecto.Migration

  def change do
    alter table(:seasonal_disposition_states, prefix: "platform") do
      add(:last_disposition, :text)
      add(:last_status, :text)
      add(:last_score, :float)
      add(:last_evaluated_at, :utc_datetime_usec)
    end
  end
end
