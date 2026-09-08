defmodule ServiceRadarWebNG.SRQLDecodeParamTest do
  @moduledoc """
  Database-free unit tests for `ServiceRadarWebNG.SRQL.decode_param/1`.

  `decode_param/1` is exported (`@doc false`, not `defp`) specifically so it
  can be exercised directly here without a database connection, the same
  reason `session_setup_sql/0` is exported (see `SRQLPlanCacheModeTest`).
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SRQL

  @moduletag :db_free

  describe "date parameter type" do
    test "decodes a valid ISO 8601 date" do
      assert {:ok, ~D[2026-01-15]} = SRQL.decode_param(%{"t" => "date", "v" => "2026-01-15"})
    end

    test "rejects a malformed date" do
      assert {:error, :invalid_date_param} =
               SRQL.decode_param(%{"t" => "date", "v" => "not-a-date"})
    end
  end

  describe "unknown parameter type" do
    test "returns an error instead of passing the raw param through" do
      assert {:error, :invalid_srql_param} =
               SRQL.decode_param(%{"t" => "nonexistent_type", "v" => "anything"})
    end
  end
end
