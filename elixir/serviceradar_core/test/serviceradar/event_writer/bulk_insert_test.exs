defmodule ServiceRadar.EventWriter.BulkInsertTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.BulkInsert

  defmodule FakeRepo do
    def insert_all(table, rows, opts) do
      send(self(), {:insert_all, table, rows, opts})

      returned =
        if Keyword.get(opts, :returning, false) in [false, nil] do
          nil
        else
          Enum.map(rows, &Map.take(&1, [:id]))
        end

      {length(rows), returned}
    end
  end

  describe "insert_all/4" do
    test "chunks expanded rows under the PostgreSQL bind parameter limit" do
      rows = build_rows(7_015, 30)

      {count, returned} =
        BulkInsert.insert_all(FakeRepo, "otel_traces", rows,
          on_conflict: :nothing,
          returning: false
        )

      assert count == length(rows)
      assert returned == nil

      chunks = receive_chunks()

      assert length(chunks) > 1

      for {_table, chunk, _opts} <- chunks do
        assert length(chunk) * unique_bound_column_count(chunk) <=
                 BulkInsert.max_bind_parameters()
      end
    end

    test "uses the union of row columns when rows have different keys" do
      rows = [
        %{trace_id: "a", span_id: "b"},
        %{trace_id: "a", span_id: "c", service_name: "svc", created_at: DateTime.utc_now()}
      ]

      chunk_size = BulkInsert.max_rows_per_statement(rows)

      assert chunk_size * unique_bound_column_count(rows) <= BulkInsert.max_bind_parameters()
    end

    test "does not count Ecto placeholders as per-row bind parameters" do
      rows = [
        %{id: 1, inserted_at: {:placeholder, :now}},
        %{id: 2, inserted_at: {:placeholder, :now}}
      ]

      assert BulkInsert.max_rows_per_statement(rows) ==
               div(BulkInsert.max_bind_parameters(), 1)
    end

    test "merges returned rows across chunks" do
      rows = build_rows(7_015, 30)

      {count, returned} =
        BulkInsert.insert_all(FakeRepo, "ocsf_events", rows,
          on_conflict: :nothing,
          returning: [:id]
        )

      assert count == length(rows)
      assert Enum.map(returned, & &1.id) == Enum.map(rows, & &1.id)
      assert length(receive_chunks()) > 1
    end

    test "returns the same shape as Ecto insert_all for empty inserts" do
      assert BulkInsert.insert_all(FakeRepo, "logs", [], returning: false) == {0, nil}
      assert BulkInsert.insert_all(FakeRepo, "logs", [], returning: [:id]) == {0, []}
    end
  end

  defp build_rows(count, column_count) do
    columns = Enum.map(1..column_count, &String.to_atom("field_#{&1}"))

    for id <- 1..count do
      columns
      |> Enum.with_index()
      |> Map.new(fn {column, index} -> {column, "#{id}-#{index}"} end)
      |> Map.put(:id, id)
    end
  end

  defp receive_chunks(acc \\ []) do
    receive do
      {:insert_all, table, rows, opts} -> receive_chunks([{table, rows, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp unique_bound_column_count(rows) do
    rows
    |> Enum.reduce(MapSet.new(), fn row, columns ->
      row
      |> Map.keys()
      |> Enum.reject(&match?({:placeholder, _}, Map.fetch!(row, &1)))
      |> Enum.reduce(columns, &MapSet.put(&2, &1))
    end)
    |> MapSet.size()
  end
end
