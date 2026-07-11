defmodule ServiceRadar.TestSupport.CanonicalMutationLockRepo do
  @moduledoc false

  def transaction(fun, opts) when is_function(fun, 0) do
    send(self(), {:lock_transaction, opts})

    try do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end
  end

  def query(statement, params) do
    send(self(), {:lock_query, statement, params})

    Process.get({__MODULE__, :query_result}) ||
      raise "canonical mutation lock test query result not configured"
  end

  def rollback(reason), do: throw({:rollback, reason})
end
