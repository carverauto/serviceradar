defmodule ServiceRadar.Repo.Migrations.EnsureObanPlatformTables do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    platform_jobs = regclass("platform.oban_jobs")
    public_jobs = regclass("public.oban_jobs")

    cond do
      platform_jobs != nil ->
        ensure_platform_oban_supporting_objects()

      public_jobs != nil ->
        copy_public_oban_to_platform()

      true ->
        Oban.Migrations.up(prefix: "platform")
    end
  end

  def down do
    :ok
  end

  defp copy_public_oban_to_platform do
    execute("""
    CREATE SEQUENCE IF NOT EXISTS platform.oban_jobs_id_seq;
    CREATE TABLE IF NOT EXISTS platform.oban_jobs (
      LIKE public.oban_jobs INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES
    );
    ALTER TABLE platform.oban_jobs
      ALTER COLUMN id SET DEFAULT nextval('platform.oban_jobs_id_seq'::regclass);
    ALTER SEQUENCE platform.oban_jobs_id_seq OWNED BY platform.oban_jobs.id;
    """)

    execute("""
    CREATE UNLOGGED TABLE IF NOT EXISTS platform.oban_peers (
      name text NOT NULL,
      node text NOT NULL,
      started_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      PRIMARY KEY (name)
    );
    """)
  end

  defp ensure_platform_oban_supporting_objects do
    execute("""
    CREATE SEQUENCE IF NOT EXISTS platform.oban_jobs_id_seq;
    ALTER TABLE platform.oban_jobs
      ALTER COLUMN id SET DEFAULT nextval('platform.oban_jobs_id_seq'::regclass);
    ALTER SEQUENCE platform.oban_jobs_id_seq OWNED BY platform.oban_jobs.id;
    """)

    execute("""
    CREATE UNLOGGED TABLE IF NOT EXISTS platform.oban_peers (
      name text NOT NULL,
      node text NOT NULL,
      started_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      PRIMARY KEY (name)
    );
    """)
  end

  defp regclass(name) do
    %{rows: [[value]]} = repo().query!("SELECT to_regclass($1)", [name])
    value
  end
end
