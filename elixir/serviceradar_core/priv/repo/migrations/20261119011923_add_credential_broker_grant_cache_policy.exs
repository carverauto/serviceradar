defmodule ServiceRadar.Repo.Migrations.AddCredentialBrokerGrantCachePolicy do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:credential_broker_grants, prefix: "platform") do
      add :cache_mode, :text, null: false, default: "no_cache"
      add :cache_ttl_seconds, :integer
    end

    create constraint(:credential_broker_grants, :credential_broker_grants_cache_ttl_bounds,
             prefix: "platform",
             check:
               "(cache_mode = 'no_cache' AND cache_ttl_seconds IS NULL) OR " <>
                 "(cache_mode = 'memory_ttl' AND cache_ttl_seconds BETWEEN 1 AND 300)"
           )
  end

  def down do
    drop constraint(:credential_broker_grants, :credential_broker_grants_cache_ttl_bounds,
           prefix: "platform"
         )

    alter table(:credential_broker_grants, prefix: "platform") do
      remove :cache_mode
      remove :cache_ttl_seconds
    end
  end
end
