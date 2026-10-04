defmodule ServiceRadar.Repo.Migrations.AddHomepagePreferences do
  @moduledoc """
  Homepage choice on a user and on a user group.

  Null on a user means inherit. Null on a group means that group has no
  homepage. The check expression lives in
  `ServiceRadar.Identity.Homepage.preference_check_sql/0`.
  """

  use Ecto.Migration

  def up do
    alter table(:ng_users, prefix: "platform") do
      add :homepage_kind, :text
      add :homepage_target, :text
    end

    alter table(:user_groups, prefix: "platform") do
      add :homepage_kind, :text
      add :homepage_target, :text
    end

    check = ServiceRadar.Identity.Homepage.preference_check_sql()

    execute(
      "ALTER TABLE platform.ng_users ADD CONSTRAINT ng_users_homepage_preference_check CHECK (#{check})",
      "ALTER TABLE platform.ng_users DROP CONSTRAINT IF EXISTS ng_users_homepage_preference_check"
    )

    execute(
      "ALTER TABLE platform.user_groups ADD CONSTRAINT user_groups_homepage_preference_check CHECK (#{check})",
      "ALTER TABLE platform.user_groups DROP CONSTRAINT IF EXISTS user_groups_homepage_preference_check"
    )
  end

  def down do
    execute("ALTER TABLE platform.ng_users DROP CONSTRAINT IF EXISTS ng_users_homepage_preference_check")
    execute("ALTER TABLE platform.user_groups DROP CONSTRAINT IF EXISTS user_groups_homepage_preference_check")

    alter table(:ng_users, prefix: "platform") do
      remove :homepage_target
      remove :homepage_kind
    end

    alter table(:user_groups, prefix: "platform") do
      remove :homepage_target
      remove :homepage_kind
    end
  end
end
