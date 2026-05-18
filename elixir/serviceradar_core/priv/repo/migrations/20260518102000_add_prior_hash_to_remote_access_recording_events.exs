defmodule ServiceRadar.Repo.Migrations.AddPriorHashToRemoteAccessRecordingEvents do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:remote_access_recording_events, prefix: @prefix) do
      add(:prior_event_hash, :text)
    end
  end
end
