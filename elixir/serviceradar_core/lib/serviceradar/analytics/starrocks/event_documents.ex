defmodule ServiceRadar.Analytics.StarRocks.EventDocuments do
  @moduledoc """
  Gives an event row read from the warehouse the shape CNPG gives it.

  `serviceradar.events` keeps the `metadata`, `unmapped`, `device` and
  `observables` documents as JSON text (`priv/starrocks/0018`, written by
  `Rows.encode(:events, ...)`), where CNPG holds them as jsonb and hands back
  maps and lists. Every reader of an event row indexes into those documents, so
  they are decoded here, once, for each path that turns a warehouse result into
  row maps: a caller must not have to know which backend answered.

  Only those four columns, and only for an entity of the events dataset. A
  value that does not decode is left as it was and reported at debug level:
  one bad document must not take a page down with it.

  MTR rows get the same treatment for the same reason. A hop's `ecmp_addrs`
  (`ARRAY`) and `mpls_labels` (`JSON`) arrive as their JSON text, and a trace's
  `target_reached` `BOOLEAN` as a 0/1 `TINYINT` over the MySQL protocol, where
  CNPG returns a list, a document and a boolean. Only a row listing carries
  those columns; a stats row (which has no `id`) is left alone, so an
  aggregate aliased to one of those names is never rewritten.
  """

  alias ServiceRadar.Analytics.StarRocks.Readers

  require Logger

  @columns ~w(metadata unmapped device observables)
  @mtr_columns ~w(ecmp_addrs mpls_labels)

  @spec decode_rows([map()], String.t() | nil) :: [map()]
  def decode_rows(rows, entity) when is_list(rows) and is_binary(entity) do
    case Readers.dataset_for_entity(entity) do
      :events -> Enum.map(rows, &decode_row(&1, @columns))
      :mtr -> Enum.map(rows, &decode_mtr_row/1)
      _ -> rows
    end
  end

  def decode_rows(rows, _entity), do: rows

  defp decode_mtr_row(%{"id" => _} = row) do
    case decode_row(row, @mtr_columns) do
      %{"target_reached" => reached} = decoded when reached in [0, 1, "0", "1"] ->
        Map.put(decoded, "target_reached", reached in [1, "1"])

      decoded ->
        decoded
    end
  end

  defp decode_mtr_row(row), do: row

  defp decode_row(%{} = row, columns) do
    Enum.reduce(columns, row, fn column, acc ->
      case acc do
        %{^column => value} when is_binary(value) -> Map.put(acc, column, decode(column, value))
        _ -> acc
      end
    end)
  end

  defp decode_row(row, _columns), do: row

  defp decode(column, value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        decoded

      _ ->
        Logger.debug("StarRocks document column is not a JSON object or array", column: column)
        value
    end
  end
end
