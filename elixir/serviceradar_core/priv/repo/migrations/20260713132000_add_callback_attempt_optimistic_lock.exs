defmodule ServiceRadar.Repo.Migrations.AddCallbackAttemptOptimisticLock do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:automation_callback_command_attempts, prefix: "platform") do
      add :lock_version, :bigint, null: false, default: 1
    end
  end
end
