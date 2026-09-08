defmodule ServiceRadar.Repo.Migrations.AddNorthboundActionCallbackFields do
  use Ecto.Migration

  def change do
    alter table(:northbound_action_invocation_targets, prefix: "platform") do
      add :callback_token_hash, :text
      add :callback_url, :text
      add :callback_received_at, :utc_datetime_usec
    end
  end
end
