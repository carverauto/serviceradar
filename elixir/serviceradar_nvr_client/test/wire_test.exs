defmodule ServiceRadarNVRClient.WireTest do
  use ExUnit.Case, async: true

  alias ServiceRadarNVRClient.Wire

  @storage_id "00000000-0000-4000-8000-000000000011"
  @block_id String.duplicate("a", 64)
  @digest String.duplicate("b", 64)

  test "lookup and block_page require nonnegative bytes for sealed and incomplete blocks" do
    sealed = %{
      "block_id" => @block_id,
      "state" => "sealed",
      "writing" => false,
      "bytes" => 0,
      "descriptor_sha256" => @digest
    }

    incomplete = %{
      "block_id" => @block_id,
      "state" => "incomplete",
      "writing" => true,
      "bytes" => 512
    }

    for entry <- [sealed, incomplete] do
      assert {:ok, %{storage_id: @storage_id, blocks: [_]}} =
               Wire.lookup(encode_lookup([entry]), [@block_id])

      assert {:ok, %{storage_id: @storage_id, blocks: [_], next_after: nil}} =
               Wire.block_page(encode_page([entry], nil), nil, 10)

      for invalid_bytes <- [nil, -1, "512"] do
        bad = Map.put(entry, "bytes", invalid_bytes)
        assert {:error, :invalid_response} = Wire.lookup(encode_lookup([bad]), [@block_id])
        assert {:error, :invalid_response} = Wire.block_page(encode_page([bad], nil), nil, 10)
      end
    end
  end

  test "lookup and block_page allow nil or nonnegative bytes for unresolved and require nil for absent" do
    for bytes <- [nil, 0, 128] do
      unresolved = %{
        "block_id" => @block_id,
        "state" => "unresolved",
        "writing" => false,
        "bytes" => bytes,
        "reason" => "invalid_journal_record"
      }

      assert {:ok, %{blocks: [%{state: :unresolved, bytes: ^bytes}]}} =
               Wire.lookup(encode_lookup([unresolved]), [@block_id])

      assert {:ok, %{blocks: [%{state: :unresolved, bytes: ^bytes}]}} =
               Wire.block_page(encode_page([unresolved], nil), nil, 10)
    end

    bad_unresolved = %{
      "block_id" => @block_id,
      "state" => "unresolved",
      "writing" => false,
      "bytes" => -1,
      "reason" => "invalid_journal_record"
    }

    assert {:error, :invalid_response} = Wire.lookup(encode_lookup([bad_unresolved]), [@block_id])

    absent = %{"block_id" => @block_id, "state" => "absent", "writing" => false, "bytes" => nil}
    assert {:ok, %{blocks: [%{state: :absent, bytes: nil}]}} = Wire.lookup(encode_lookup([absent]), [@block_id])

    bad_absent = Map.put(absent, "bytes", 0)
    assert {:error, :invalid_response} = Wire.lookup(encode_lookup([bad_absent]), [@block_id])
  end

  defp encode_lookup(blocks) do
    Jason.encode!(%{"version" => 1, "storage_id" => @storage_id, "blocks" => blocks})
  end

  defp encode_page(blocks, next_after) do
    Jason.encode!(%{"version" => 1, "storage_id" => @storage_id, "blocks" => blocks, "next_after" => next_after})
  end
end
