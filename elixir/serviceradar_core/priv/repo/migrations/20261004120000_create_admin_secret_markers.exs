defmodule ServiceRadar.Repo.Migrations.CreateAdminSecretMarkers do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:admin_secret_markers, primary_key: false, prefix: "platform") do
      add :admin_email, :citext, primary_key: true, null: false
      add :secret_digest, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
