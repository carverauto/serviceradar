defmodule ServiceRadar.Analytics.StarRocks.RowsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Rows

  @moduletag :db_free

  # 65_533 is the StarRocks events.message VARCHAR limit (priv/starrocks/0004).
  @message_limit 65_533

  defp encode_event(overrides) do
    Map.merge(
      %{
        "id" => "evt-alpha-0001",
        "time" => ~U[2026-09-22 12:00:00Z],
        "class_uid" => 1004,
        "message" => "scan complete",
        "metadata" => %{},
        "unmapped" => %{},
        "device" => %{},
        "observables" => []
      },
      overrides
    )
  end

  test "an oversized message is truncated so the event still lands" do
    message = String.duplicate("x", @message_limit + 100)

    assert [%{"message" => truncated}] =
             Rows.encode(:events, [encode_event(%{"message" => message})])

    assert byte_size(truncated) == @message_limit
    assert String.valid?(truncated)
    assert truncated == String.duplicate("x", @message_limit)
  end

  test "an oversized source is truncated to its 256-byte column limit" do
    source = String.duplicate("s", 300)

    assert [%{"source" => truncated}] =
             Rows.encode(:events, [encode_event(%{"source" => source})])

    assert byte_size(truncated) == 256
  end

  test "a multi-byte value truncates on a UTF-8 boundary rather than mid-codepoint" do
    # 40_000 precomposed "e-acute" is 80_000 bytes; the cut would otherwise
    # fall inside the final codepoint and produce invalid UTF-8.
    message = String.duplicate("é", 40_000)

    assert [%{"message" => truncated}] =
             Rows.encode(:events, [encode_event(%{"message" => message})])

    assert byte_size(truncated) <= @message_limit
    assert String.valid?(truncated)
    assert rem(byte_size(truncated), 2) == 0
  end

  test "a normal event row is unchanged" do
    row = encode_event(%{})

    assert [encoded] = Rows.encode(:events, [row])

    assert encoded["message"] == "scan complete"
    assert encoded["id"] == "evt-alpha-0001"
    assert encoded["metadata"] == "{}"
    assert encoded["observables"] == "[]"
  end
end
