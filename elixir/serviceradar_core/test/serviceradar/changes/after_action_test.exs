defmodule ServiceRadar.Changes.AfterActionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Changes.AfterAction

  test "returns the original record after running the callback" do
    record = %{id: "record-1"}

    assert AfterAction.run(record, fn received_record ->
             assert received_record == record
             :ok
           end) == {:ok, record}
  end
end
