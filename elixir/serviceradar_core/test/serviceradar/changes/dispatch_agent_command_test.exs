defmodule ServiceRadar.Changes.DispatchAgentCommandTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Changes.DispatchAgentCommand

  test "returns the original record after a successful dispatch" do
    record = %{id: "record-1"}
    actor = %{id: "actor-1"}

    assert DispatchAgentCommand.run(record, actor, fn received_record, opts ->
             assert received_record == record
             assert Keyword.get(opts, :actor) == actor
             {:ok, "command-1"}
           end) == {:ok, record}
  end

  test "returns the dispatch error unchanged" do
    record = %{id: "record-1"}

    assert DispatchAgentCommand.run(record, nil, fn _record, _opts ->
             {:error, :agent_offline}
           end) == {:error, :agent_offline}
  end
end
