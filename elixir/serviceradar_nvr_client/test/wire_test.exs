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

    reclaimed = %{"block_id" => @block_id, "state" => "reclaimed", "writing" => false, "bytes" => nil}
    assert {:ok, %{blocks: [%{state: :reclaimed, bytes: nil}]}} = Wire.lookup(encode_lookup([reclaimed]), [@block_id])

    assert {:ok, %{blocks: [%{state: :reclaimed, bytes: nil}]}} =
             Wire.block_page(encode_page([reclaimed], nil), nil, 10)

    bad_reclaimed = Map.put(reclaimed, "bytes", 0)
    assert {:error, :invalid_response} = Wire.lookup(encode_lookup([bad_reclaimed]), [@block_id])
  end

  test "reclaim_request and reclaim_receipt validate canonical fields and bindings" do
    generation = "00000000-0000-4000-8000-000000000077"
    operation_id = "00000000-0000-4000-8000-000000000088"

    request = %{
      "version" => 1,
      "storage_id" => @storage_id,
      "recovery_generation" => generation,
      "operation_id" => operation_id,
      "expected_descriptor_sha256" => @digest
    }

    assert {:ok, body} = Wire.reclaim_request(@block_id, request)
    assert Jason.decode!(body) == request

    for invalid <- [
          Map.put(request, "version", 2),
          Map.put(request, "storage_id", "not-a-uuid"),
          Map.put(request, "operation_id", "not-a-uuid"),
          Map.put(request, "expected_descriptor_sha256", "short"),
          Map.put(request, "extra", true),
          Map.delete(request, "operation_id")
        ] do
      assert {:error, :invalid_reclaim_request} = Wire.reclaim_request(@block_id, invalid)
    end

    assert {:error, :invalid_reclaim_request} = Wire.reclaim_request("not-a-block-id", request)

    receipt = %{
      "version" => 1,
      "status" => "reclaimed",
      "storage_id" => @storage_id,
      "block_id" => @block_id,
      "operation_id" => operation_id,
      "reclaimed_at_ms" => 1_700_000_000_000
    }

    assert {:ok,
            %{
              storage_id: @storage_id,
              block_id: @block_id,
              operation_id: ^operation_id,
              status: :reclaimed,
              reclaimed_at_ms: 1_700_000_000_000
            }} = Wire.reclaim_receipt(Jason.encode!(receipt), @block_id, request)

    for bad_receipt <- [
          Map.put(receipt, "operation_id", "00000000-0000-4000-8000-000000000099"),
          Map.put(receipt, "block_id", String.duplicate("c", 64)),
          Map.put(receipt, "status", "absent"),
          Map.put(receipt, "reclaimed_at_ms", 0),
          Map.put(receipt, "extra", true)
        ] do
      assert {:error, :outcome_unknown} = Wire.reclaim_receipt(Jason.encode!(bad_receipt), @block_id, request)
    end
  end

  defp encode_lookup(blocks) do
    Jason.encode!(%{"version" => 1, "storage_id" => @storage_id, "blocks" => blocks})
  end

  defp encode_page(blocks, next_after) do
    Jason.encode!(%{"version" => 1, "storage_id" => @storage_id, "blocks" => blocks, "next_after" => next_after})
  end
end
