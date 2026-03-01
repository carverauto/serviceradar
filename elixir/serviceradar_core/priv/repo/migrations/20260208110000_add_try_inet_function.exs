defmodule ServiceRadar.Repo.Migrations.AddTryInetFunction do
  @moduledoc """
  Adds `platform.try_inet(text) -> inet`.

  SRQL needs to safely cast `src_endpoint_ip`/`dst_endpoint_ip` to `inet` in
  stats/group-by expressions (e.g. `src_cidr:24`) and CIDR filters.
  If any row contains a non-empty but invalid IP string, a plain `::inet` cast
  will error and break the entire query. `try_inet/1` turns those cases into NULL.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION platform.try_inet(value text)
    RETURNS inet
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    BEGIN
      IF value IS NULL OR value = '' THEN
        RETURN NULL;
      END IF;

      RETURN value::inet;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
    $$;
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS platform.try_inet(text)")
  end
end

