defmodule ServiceRadar.GraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Graph

  defmodule RetryRepo do
    def query(sql, [], opts) do
      calls = Process.get(:graph_retry_repo_calls, [])
      Process.put(:graph_retry_repo_calls, calls ++ [{sql, opts}])

      case calls do
        [] -> {:error, :transient_failure}
        _ -> {:ok, %{rows: []}}
      end
    end
  end

  defmodule FailingRepo do
    def query(sql, [], opts) do
      calls = Process.get(:graph_failing_repo_calls, [])
      Process.put(:graph_failing_repo_calls, calls ++ [{sql, opts}])

      case calls do
        [] -> {:error, :first_failure}
        _ -> {:error, :masked_failure}
      end
    end
  end

  test "execute retries dollar-quoted AGE cypher before compatibility fallback" do
    Process.delete(:graph_retry_repo_calls)

    assert :ok = Graph.execute("RETURN 1", repo: RetryRepo)

    calls = Process.get(:graph_retry_repo_calls)

    assert length(calls) == 2

    assert Enum.all?(calls, fn {sql, opts} ->
             String.contains?(sql, "$sr_") and opts == [prepare: :unnamed]
           end)
  end

  test "execute preserves the first failure when every AGE candidate fails" do
    Process.delete(:graph_failing_repo_calls)

    assert {:error, :first_failure} = Graph.execute("RETURN 1", repo: FailingRepo)

    assert length(Process.get(:graph_failing_repo_calls)) == 3
  end
end
