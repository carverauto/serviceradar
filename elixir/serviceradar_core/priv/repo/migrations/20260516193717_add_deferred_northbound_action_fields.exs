defmodule ServiceRadar.Repo.Migrations.AddDeferredNorthboundActionFields do
  @moduledoc false

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:northbound_action_invocation_targets, prefix: @prefix) do
      add(:continuation_state, :map, null: false, default: %{})
      add(:next_poll_at, :utc_datetime_usec)
      add(:poll_deadline_at, :utc_datetime_usec)
      add(:last_poll_at, :utc_datetime_usec)
      add(:poll_attempt_count, :integer, null: false, default: 0)
    end

    create(
      index(:northbound_action_invocation_targets, [:status, :next_poll_at],
        name: :northbound_action_targets_poll_due_idx,
        prefix: @prefix,
        where: "next_poll_at IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:northbound_action_invocation_targets, [:status, :next_poll_at],
        name: :northbound_action_targets_poll_due_idx,
        prefix: @prefix
      )
    )

    alter table(:northbound_action_invocation_targets, prefix: @prefix) do
      remove(:poll_attempt_count)
      remove(:last_poll_at)
      remove(:poll_deadline_at)
      remove(:next_poll_at)
      remove(:continuation_state)
    end
  end
end
