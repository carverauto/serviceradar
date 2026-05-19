defmodule ServiceRadar.Repo.Migrations.EncryptRemoteAccessRecordings do
  @moduledoc """
  Adds AshCloak ciphertext columns for remote-access recording manifests and payload text.

  The legacy plaintext columns remain present for rollback compatibility and for
  older rows, but current resources write new manifest/payload data through
  AshCloak into these encrypted columns.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:remote_access_recordings, prefix: @prefix) do
      add(:encrypted_manifest, :binary)
    end

    alter table(:remote_access_recording_events, prefix: @prefix) do
      add(:encrypted_payload_text, :binary)
    end
  end

  def down do
    alter table(:remote_access_recording_events, prefix: @prefix) do
      remove(:encrypted_payload_text)
    end

    alter table(:remote_access_recordings, prefix: @prefix) do
      remove(:encrypted_manifest)
    end
  end
end
