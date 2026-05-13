defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessRecordingEvents do
  @moduledoc """
  Creates policy-gated remote-access replay events.

  Payload text is optional and remains empty for metadata-only recordings.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_recording_events, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :recording_id,
        references(:remote_access_recordings,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :session_id,
        references(:remote_access_sessions,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:sequence, :bigint, null: false)
      add(:stream, :text, null: false)
      add(:event_type, :text, null: false)
      add(:occurred_at, :utc_datetime, null: false)
      add(:byte_count, :bigint, null: false, default: 0)
      add(:payload_sha256, :text)
      add(:payload_text, :text)
      add(:payload_redacted, :boolean, null: false, default: false)
      add(:redaction_reason, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:retention_expires_at, :utc_datetime)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:remote_access_recording_events, [:recording_id, :sequence],
        name: :remote_access_recording_events_recording_sequence_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_recording_events, [:session_id, :sequence],
        name: :remote_access_recording_events_session_sequence_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_recording_events, [:retention_expires_at],
        name: :remote_access_recording_events_retention_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_recording_events,
        :remote_access_recording_events_sequence_positive,
        check: "sequence > 0",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_recording_events,
        :remote_access_recording_events_byte_count_nonnegative,
        check: "byte_count >= 0",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_recording_events, prefix: @prefix))
  end
end
