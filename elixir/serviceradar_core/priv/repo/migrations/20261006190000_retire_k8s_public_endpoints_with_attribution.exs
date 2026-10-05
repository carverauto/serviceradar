defmodule ServiceRadar.Repo.Migrations.RetireK8sPublicEndpointsWithAttribution do
  @moduledoc false
  use Ecto.Migration

  def change do
    schema = prefix() || "platform"

    alter table(:public_endpoints_current, prefix: schema) do
      add :deleted_by, :text
    end
  end
end
