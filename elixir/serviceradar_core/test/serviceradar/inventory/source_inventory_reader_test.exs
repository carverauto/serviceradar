defmodule ServiceRadar.Inventory.SourceInventoryReaderTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.SourceInventoryReader

  test "accepts only bounded typed filters" do
    assert {:ok, opts} =
             SourceInventoryReader.parse_params(%{
               "source" => "Example-Inventory",
               "instance" => "acme-prod",
               "presence" => "present",
               "partition" => "default",
               "limit" => "250"
             })

    assert opts.source == "example-inventory"
    assert opts.instance == "acme-prod"
    assert opts.limit == 250

    assert {:error, {:invalid_query, :unknown_query_parameter}} =
             SourceInventoryReader.parse_params(%{
               "source" => "example-inventory",
               "instance" => "acme-prod",
               "sql" => "SELECT * FROM platform.ocsf_devices"
             })

    assert {:error, {:invalid_query, :invalid_limit}} =
             SourceInventoryReader.parse_params(%{
               "source" => "example-inventory",
               "instance" => "acme-prod",
               "limit" => "501"
             })

    assert {:error, {:invalid_query, :invalid_identifier}} =
             SourceInventoryReader.parse_params(%{
               "source" => "example-inventory",
               "instance" => "acme-prod' OR 1=1 --"
             })
  end

  test "rejects malformed and query-rebound cursors" do
    assert {:error, {:invalid_query, :invalid_cursor}} =
             SourceInventoryReader.decode_cursor("not-a-cursor")

    encoded =
      %{
        "v" => 1,
        "source" => "example-inventory",
        "instance" => "acme-prod",
        "partition" => "default",
        "presence" => "present",
        "collection" => "20260713T120000.000000000Z-abcdef123456",
        "last_observed_at" => "2026-07-13T12:00:00.000000Z",
        "id" => Ecto.UUID.generate()
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, cursor} = SourceInventoryReader.decode_cursor(encoded)
    assert cursor.collection == "20260713T120000.000000000Z-abcdef123456"

    assert {:error, {:invalid_query, :cursor_query_mismatch}} =
             SourceInventoryReader.parse_params(%{
               "source" => "example-inventory",
               "instance" => "another-instance",
               "cursor" => encoded
             })
  end
end
