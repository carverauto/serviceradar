defmodule ServiceRadar.Repo.Migrations.VerifyUserTimezonePreference do
  @moduledoc """
  Verifies the user timezone column before the chart can report migrations ready.

  The original timezone migration keeps its 20260830211630 version because that
  version has already run on persistent clusters. This later marker prevents a
  higher, unrelated migration from satisfying the chart's readiness check when
  the timezone migration has not run.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'platform'
          AND table_name = 'ng_users'
          AND column_name = 'timezone'
          AND data_type = 'text'
          AND is_nullable = 'NO'
          AND column_default = '''Etc/UTC''::text'
      ) THEN
        RAISE EXCEPTION
          'platform.ng_users.timezone must be non-null text with an Etc/UTC default';
      END IF;
    END
    $$;
    """)
  end

  def down, do: :ok
end
