defmodule ServiceRadar.Repo.Migrations.AddAdvisoryContentHash do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:vulnerability_advisories, prefix: "platform") do
      add :content_hash, :text
    end
  end
end
