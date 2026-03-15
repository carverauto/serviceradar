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

  test "run_result preserves the original record for ok tuples" do
    record = %{id: "record-1"}

    assert AfterAction.run_result(record, fn received_record ->
             assert received_record == record
             {:ok, :side_effect_result}
           end) == {:ok, record}
  end

  test "run_result returns callback errors unchanged" do
    record = %{id: "record-1"}

    assert AfterAction.run_result(record, fn _received_record ->
             {:error, :failed}
           end) == {:error, :failed}
  end
end
