defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessRecordings do
  @moduledoc """
  Creates policy-gated remote-access recording manifests.

  The table stores recording lifecycle, retention, storage pointers, and byte
  counters. It intentionally does not store terminal input/output payloads.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_recordings, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :session_id,
        references(:remote_access_sessions,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:status, :text, null: false, default: "pending")
      add(:policy, :map, null: false, default: %{})
      add(:storage_backend, :text, null: false)
      add(:storage_bucket, :text)
      add(:object_key, :text, null: false)
      add(:manifest, :map, null: false, default: %{})
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:retention_expires_at, :utc_datetime)
      add(:input_bytes, :bigint, null: false, default: 0)
      add(:output_bytes, :bigint, null: false, default: 0)
      add(:event_count, :bigint, null: false, default: 0)
      add(:failure_reason, :text)

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
      unique_index(:remote_access_recordings, [:session_id],
        name: :remote_access_recordings_session_id_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_recordings, [:status, :retention_expires_at],
        name: :remote_access_recordings_status_retention_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_recordings, [:storage_backend, :storage_bucket],
        name: :remote_access_recordings_storage_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_recordings, :remote_access_recordings_input_bytes_nonnegative,
        check: "input_bytes >= 0",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_recordings, :remote_access_recordings_output_bytes_nonnegative,
        check: "output_bytes >= 0",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_recordings, :remote_access_recordings_event_count_nonnegative,
        check: "event_count >= 0",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_recordings, prefix: @prefix))
  end
end
