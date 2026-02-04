defmodule ServiceRadar.Repo.Migrations.AddAgentCommands do
  @moduledoc """
  Adds persistent agent command lifecycle records.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:agent_commands, primary_key: false, prefix: "platform") do
      add :command_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true

      add :command_type, :text, null: false
      add :agent_id, :text, null: false
      add :partition_id, :text, null: false, default: "default"
      add :status, :text, null: false, default: "queued"
      add :payload, :map
      add :context, :map
      add :result_payload, :map
      add :message, :text
      add :failure_reason, :text
      add :progress_percent, :integer
      add :ttl_seconds, :bigint, default: 60
      add :expires_at, :utc_datetime
      add :sent_at, :utc_datetime
      add :acknowledged_at, :utc_datetime
      add :started_at, :utc_datetime
      add :last_progress_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :canceled_at, :utc_datetime
      add :requested_by, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    drop table(:agent_commands, prefix: "platform")
  end
end
