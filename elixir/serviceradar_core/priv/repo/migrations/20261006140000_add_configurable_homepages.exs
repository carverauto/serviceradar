defmodule ServiceRadar.Repo.Migrations.AddConfigurableHomepages do
  @moduledoc """
  Configurable default homepage (`add-configurable-default-homepage`).

  Adds the per-user homepage, the per-group homepage with its tie-break
  priority, and the deployment default. Each homepage is a
  `ServiceRadar.Identity.Homepage` map (never a URL); the check constraints
  mirror its allowed kinds so a row written around the Ash actions still
  cannot carry a free-text path.

  Then copies each user's dashboards-hub default (`dashboard_user_preferences.is_default`,
  at most one per user by index) into `ng_users.homepage` where the user has
  none, so the hub's "Set as default" and the profile homepage are one value.
  `is_default` is left in place and dropped in a later release.
  """

  use Ecto.Migration

  @prefix "platform"
  @backfill_sql """
    UPDATE platform.ng_users AS u
    SET homepage = jsonb_build_object(
      'kind', 'dashboard',
      'target_type', p.target_type,
      'target_id', p.target_id
    )
    FROM platform.dashboard_user_preferences AS p
    WHERE p.user_id = u.id
      AND p.is_default
      AND p.target_type IN ('authored', 'package')
      AND u.homepage IS NULL
  """

  @kind_check "homepage IS NULL OR (jsonb_typeof(homepage) = 'object' AND homepage->>'kind' IN ('overview', 'dashboards_index', 'dashboard'))"

  def up do
    alter table(:ng_users, prefix: @prefix) do
      add_if_not_exists(:homepage, :map, null: true)
    end

    alter table(:user_groups, prefix: @prefix) do
      add_if_not_exists(:homepage, :map, null: true)
      add_if_not_exists(:homepage_priority, :integer, null: false, default: 100)
    end

    alter table(:authorization_settings, prefix: @prefix) do
      add_if_not_exists(:default_homepage, :map, null: true)
    end

    for {table, name, check} <- constraints() do
      execute("ALTER TABLE platform.#{table} DROP CONSTRAINT IF EXISTS #{name}")
      execute("ALTER TABLE platform.#{table} ADD CONSTRAINT #{name} CHECK (#{check})")
    end

    # serviceradar:allow-startup-maintenance - bounded hub-default copy required so the
    # dashboards hub "Set as default" and the profile homepage are one value (D6).
    # Only fills users with no homepage, so a re-run never overwrites a choice.
    # Bounded to ng_users rows whose is_default hub preference exists, touches no
    # telemetry table, is idempotent, and is a no-op when no hub defaults exist.
    execute(backfill_sql())
  end

  # One statement so a scratch database can rerun the hub-default copy and
  # prove it fills an empty homepage without replacing one already set.
  def backfill_sql, do: @backfill_sql

  # Reversible: the backfill only copied `is_default`, which is left in place,
  # so dropping the new columns restores the previous state.
  def down do
    for {table, name, _check} <- Enum.reverse(constraints()) do
      execute("ALTER TABLE platform.#{table} DROP CONSTRAINT IF EXISTS #{name}")
    end

    alter table(:authorization_settings, prefix: @prefix) do
      remove_if_exists(:default_homepage, :map)
    end

    alter table(:user_groups, prefix: @prefix) do
      remove_if_exists(:homepage_priority, :integer)
      remove_if_exists(:homepage, :map)
    end

    alter table(:ng_users, prefix: @prefix) do
      remove_if_exists(:homepage, :map)
    end
  end

  defp constraints do
    [
      {"ng_users", "ng_users_homepage_kind_check", @kind_check},
      {"user_groups", "user_groups_homepage_kind_check", @kind_check},
      {"user_groups", "user_groups_homepage_priority_range_check",
       "homepage_priority BETWEEN 0 AND 10000"},
      {"authorization_settings", "authorization_settings_default_homepage_kind_check",
       String.replace(@kind_check, "homepage", "default_homepage")}
    ]
  end
end
