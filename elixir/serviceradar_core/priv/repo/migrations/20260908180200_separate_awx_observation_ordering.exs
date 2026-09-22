defmodule ServiceRadar.Repo.Migrations.SeparateAwxObservationOrdering do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:ansible_awx_inventory_observations, primary_key: false, prefix: "platform") do
      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, prefix: "platform", on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:source_generation, :bigint, null: false)
      add(:source_fingerprint, :text, null: false)
      add(:observation_digest, :text, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:complete, :boolean, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:ansible_awx_inventory_observations, :awx_observation_generation_positive,
        check: "source_generation > 0",
        prefix: "platform"
      )
    )

    create(
      constraint(:ansible_awx_inventory_observations, :awx_observation_fingerprint_format,
        check:
          "source_fingerprint ~ '^sha256:[0-9a-f]{64}$' AND observation_digest ~ '^[0-9a-f]{64}$'",
        prefix: "platform"
      )
    )
  end
end
