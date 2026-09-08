defmodule ServiceRadarWebNG.SRQLResultValueTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SRQL

  @moduletag :db_free

  test "typed naive database timestamps are encoded as canonical UTC instants" do
    assert SRQL.encode_result_value(~N[2026-09-01 10:32:04]) == "2026-09-01T10:32:04Z"
  end

  test "DateTime values keep their UTC offset" do
    assert SRQL.encode_result_value(~U[2026-09-01 10:32:04Z]) == "2026-09-01T10:32:04Z"
  end
end
