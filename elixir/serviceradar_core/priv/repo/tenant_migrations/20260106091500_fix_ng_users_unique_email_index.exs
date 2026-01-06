defmodule ServiceRadar.Repo.Migrations.FixNgUsersUniqueEmailIndex do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:ng_users, [:tenant_id, :email],
                     name: "ng_users_unique_email_index"
                   )

    create unique_index(:ng_users, [:email], name: "ng_users_unique_email_index")
  end

  def down do
    drop_if_exists unique_index(:ng_users, [:email], name: "ng_users_unique_email_index")

    create unique_index(:ng_users, [:tenant_id, :email],
             name: "ng_users_unique_email_index"
           )
  end
end
