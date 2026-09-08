defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalMutationLock do
  @moduledoc false

  alias ServiceRadar.Repo

  @lock_key 1_104_202_506
  @default_timeout_ms 60_000

  @doc false
  @spec try_run((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def try_run(fun, opts \\ []) when is_function(fun, 0) do
    repo = Keyword.get(opts, :repo, Repo)
    busy_result = Keyword.get(opts, :busy_result, :busy)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    repo.transaction(
      fn ->
        case repo.query("SELECT pg_try_advisory_xact_lock($1)", [@lock_key]) do
          {:ok, %{rows: [[true]]}} ->
            fun.()

          {:ok, %{rows: [[false]]}} ->
            busy_result

          {:ok, _unexpected} ->
            repo.rollback(:unexpected_lock_response)

          {:error, reason} ->
            repo.rollback(reason)
        end
      end,
      timeout: timeout
    )
  end
end
