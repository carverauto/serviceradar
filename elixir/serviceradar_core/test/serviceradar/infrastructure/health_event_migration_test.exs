defmodule ServiceRadar.Infrastructure.HealthEventMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260709230000_order_health_events_by_database_sequence.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  test "bounds the schema-critical backfill before taking its table lock" do
    up = migration_up_source()

    assert up =~ "serviceradar:allow-startup-maintenance"
    refute up =~ "@disable_ddl_transaction true"

    assert_in_order(up, [
      "SET LOCAL lock_timeout = '5s'",
      "SET LOCAL statement_timeout = '30s'",
      "LOCK TABLE platform.health_events IN ACCESS EXCLUSIVE MODE",
      "alter table(:health_events",
      "UPDATE platform.health_events"
    ])
  end

  test "assigns one non-null database sequence while writes remain locked out" do
    up = migration_up_source()

    assert up =~ "row_number() OVER"
    assert up =~ "ORDER BY recorded_at ASC, xmin::text::bigint ASC, ctid ASC, id ASC"
    assert up =~ ~s(@sequence "platform.health_events_event_sequence_seq")

    assert up =~
             "SET DEFAULT nextval('\#{@sequence}'::regclass)"

    assert up =~ "ALTER COLUMN event_sequence SET NOT NULL"
    assert up =~ ~s(name: "health_events_event_sequence_uidx")
  end

  defp migration_up_source do
    @migration_path
    |> File.read!()
    |> String.split("  def down do", parts: 2)
    |> hd()
  end

  defp assert_in_order(source, fragments) do
    positions =
      Enum.map(fragments, fn fragment ->
        {position, _length} = :binary.match(source, fragment)
        position
      end)

    assert positions == Enum.sort(positions)
  end
end
