defmodule ServiceRadar.Repo.Migrations.HardenRemoteAccessHostKeyRotation do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:remote_access_host_keys, prefix: @prefix) do
      add(:rejected_at, :utc_datetime)
      add(:rejected_by, :text)
      add(:rejection_reason, :text)

      add(
        :supersedes_host_key_id,
        references(:remote_access_host_keys,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_host_keys_supersedes_fkey",
          prefix: @prefix
        )
      )
    end

    create(
      index(:remote_access_host_keys, [:supersedes_host_key_id],
        name: :remote_access_host_keys_supersedes_idx,
        prefix: @prefix
      )
    )
  end
end
