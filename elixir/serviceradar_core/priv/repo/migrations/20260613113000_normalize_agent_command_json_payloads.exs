defmodule ServiceRadar.Repo.Migrations.NormalizeAgentCommandJsonPayloads do
  @moduledoc false
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - agent_commands is empty on first boot so the
  # normalization UPDATE is a no-op; on upgrades it is a single bounded one-time backfill of
  # existing command rows.

  @jsonb_map_columns [:payload, :context, :result_payload, :progress_payload]

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION platform.serviceradar_agent_command_json_object(value text)
    RETURNS jsonb
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    DECLARE
      parsed jsonb;
    BEGIN
      BEGIN
        parsed := value::jsonb;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('value', value);
      END;

      IF jsonb_typeof(parsed) = 'object' THEN
        RETURN parsed;
      END IF;

      RETURN jsonb_build_object('value', parsed);
    END;
    $$;
    """)

    Enum.each(@jsonb_map_columns, &normalize_string_jsonb_column/1)

    execute("DROP FUNCTION platform.serviceradar_agent_command_json_object(text)")
  end

  def down do
    :ok
  end

  defp normalize_string_jsonb_column(column) do
    column_name = Atom.to_string(column)

    execute("""
    UPDATE platform.agent_commands
    SET #{column_name} = platform.serviceradar_agent_command_json_object(#{column_name} #>> '{}')
    WHERE #{column_name} IS NOT NULL
      AND jsonb_typeof(#{column_name}) = 'string'
    """)
  end
end
