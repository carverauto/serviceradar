defmodule ServiceRadar.Cluster.ClusterRPC do
  @moduledoc """
  Cross-node RPC dispatch with mixed-version rolling-upgrade handling.

  During a rolling upgrade, a caller on a newly deployed gateway, core, or
  web-ng pod may reach a peer node that is still running the previous release
  and does not yet export the target `{module, function, arity}`.

  `ClusterRPC` applies one consistent rule for mixed-version windows:

    1. When a candidate peer raises or returns `:undef` for the target
       `{module, function, arity}`, that peer is treated as `:peer_too_old`
       (never logged as an error) and the next candidate peer is tried
       immediately.
    2. When every currently connected candidate peer is `:peer_too_old`, the
       call waits up to a bounded window (`:undef_wait_ms`, polling every
       `:undef_poll_ms`) and re-evaluates the candidate node resolver so the
       call succeeds as soon as a capable node joins or finishes loading.
    3. If the bound expires before any capable peer exists, `{:error, :peer_too_old}`
       is returned without crashing or logging an error.
  """

  @default_timeout_ms 5_000
  @default_undef_wait_ms 1_000
  @default_undef_poll_ms 50

  @type node_source :: node() | [node()] | (-> node() | [node()] | nil)

  @doc """
  Calls `apply(module, function, args)` on the first capable peer in
  `nodes_or_resolver`, wrapping a successful remote return value in
  `{:ok, result}`.
  """
  @spec call(node_source(), module(), atom(), [term()], timeout() | keyword()) ::
          {:ok, term()} | {:error, :peer_too_old | term()}
  def call(nodes_or_resolver, module, function, args, opts \\ [])
      when is_atom(module) and is_atom(function) and is_list(args) do
    opts = normalize_opts(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)
    unavailable_error = Keyword.get(opts, :unavailable_error, :node_unavailable)
    badrpc_error = Keyword.get(opts, :badrpc_error)

    await_capable_peer(
      fn ->
        attempt_call(
          nodes_or_resolver,
          module,
          function,
          args,
          timeout,
          rpc_call,
          unavailable_error,
          badrpc_error
        )
      end,
      opts
    )
  end

  @doc """
  Runs `attempt` until it returns something other than `:peer_too_old`, polling
  every `:undef_poll_ms` for at most `:undef_wait_ms`. Returns
  `{:error, :peer_too_old}` when the bound expires.
  """
  @spec await_capable_peer((-> result), timeout() | keyword()) :: result | {:error, :peer_too_old}
        when result: term()
  def await_capable_peer(attempt, opts \\ []) when is_function(attempt, 0) do
    opts = normalize_opts(opts)
    deadline = System.monotonic_time(:millisecond) + undef_wait_ms(opts)
    await_loop(attempt, undef_poll_ms(opts), deadline)
  end

  @doc """
  Calls `apply(module, function, args)` on the first capable peer in
  `nodes_or_resolver` and returns the remote function's result directly on
  success, or `{:error, reason}` when no peer could satisfy the call.
  """
  @spec call_unwrap(node_source(), module(), atom(), [term()], timeout() | keyword()) ::
          term() | {:error, :peer_too_old | term()}
  def call_unwrap(nodes_or_resolver, module, function, args, opts \\ [])
      when is_atom(module) and is_atom(function) and is_list(args) do
    opts = normalize_opts(opts)

    case call(nodes_or_resolver, module, function, args, opts) do
      {:ok, result} ->
        result

      {:error, {:badrpc, reason}} ->
        {:error, Keyword.get(opts, :badrpc_error, reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true when `result` is an `:rpc` or `:erpc` `:undef` failure whose top
  stacktrace frame is the called `{module, function, length(args)}`.

  An `:undef` raised inside `module.function` for a different callee has that
  callee at the head of the stacktrace and returns `false`.
  """
  @spec peer_too_old?(term(), module(), atom(), [term()] | non_neg_integer()) :: boolean()
  def peer_too_old?(result, module, function, args_or_arity)
      when is_atom(module) and is_atom(function) do
    case undef_stacktrace(result) do
      [{^module, ^function, undef_args, _location} | _] ->
        matching_arity?(undef_args, args_or_arity)

      _other ->
        false
    end
  end

  defp attempt_call(
         nodes_or_resolver,
         module,
         function,
         args,
         timeout,
         rpc_call,
         unavailable_error,
         badrpc_error
       ) do
    case resolve_nodes(nodes_or_resolver) do
      [] ->
        {:error, unavailable_error}

      nodes ->
        case call_candidates(nodes, module, function, args, timeout, rpc_call) do
          {:ok, result} -> {:ok, result}
          :peer_too_old -> :peer_too_old
          {:badrpc, reason} when is_nil(badrpc_error) -> {:error, {:badrpc, reason}}
          {:badrpc, _reason} -> {:error, badrpc_error}
        end
    end
  end

  defp await_loop(attempt, undef_poll_ms, deadline) do
    case attempt.() do
      :peer_too_old ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms > 0 do
          Process.sleep(min(undef_poll_ms, remaining_ms))
          await_loop(attempt, undef_poll_ms, deadline)
        else
          {:error, :peer_too_old}
        end

      result ->
        result
    end
  end

  defp call_candidates(nodes, module, function, args, timeout, rpc_call) do
    Enum.reduce_while(nodes, :peer_too_old, fn node, acc ->
      result = invoke_rpc(rpc_call, node, module, function, args, timeout)

      cond do
        peer_too_old?(result, module, function, args) -> {:cont, acc}
        match?({:badrpc, _reason}, result) -> {:cont, result}
        true -> {:halt, {:ok, result}}
      end
    end)
  end

  defp invoke_rpc(rpc_call, node, module, function, args, timeout) do
    rpc_call.(node, module, function, args, timeout)
  catch
    :error, {:exception, :undef, stacktrace} ->
      {:badrpc, {:EXIT, {:undef, stacktrace}}}

    :error, {:exception, reason, stacktrace} ->
      {:badrpc, {:EXIT, {reason, stacktrace}}}

    :error, {:erpc, reason} ->
      {:badrpc, reason}

    :exit, reason ->
      {:badrpc, {:EXIT, reason}}
  end

  defp resolve_nodes(resolver) when is_function(resolver, 0) do
    resolve_nodes(resolver.())
  rescue
    ArgumentError -> []
  end

  defp resolve_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
    |> Enum.uniq()
  end

  defp resolve_nodes(node) when is_atom(node) and not is_nil(node), do: [node]
  defp resolve_nodes(_other), do: []

  defp undef_stacktrace({:badrpc, {:EXIT, {:undef, stacktrace}}}) when is_list(stacktrace),
    do: stacktrace

  defp undef_stacktrace({:badrpc, {:undef, stacktrace}}) when is_list(stacktrace), do: stacktrace

  defp undef_stacktrace({:error, {:exception, :undef, stacktrace}}) when is_list(stacktrace),
    do: stacktrace

  defp undef_stacktrace({:EXIT, {:undef, stacktrace}}) when is_list(stacktrace), do: stacktrace

  defp undef_stacktrace({:undef, stacktrace}) when is_list(stacktrace), do: stacktrace

  defp undef_stacktrace(_other), do: nil

  defp matching_arity?(undef_args, args) when is_list(args) do
    undef_args == args or undef_args == length(args)
  end

  defp matching_arity?(undef_args, arity) when is_integer(arity) and arity >= 0 do
    undef_args == arity or (is_list(undef_args) and length(undef_args) == arity)
  end

  defp matching_arity?(_undef_args, _args_or_arity), do: false

  defp normalize_opts(timeout) when is_integer(timeout) or timeout == :infinity,
    do: [timeout: timeout]

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(_other), do: []

  defp undef_wait_ms(opts) do
    case Keyword.get(
           opts,
           :undef_wait_ms,
           Application.get_env(
             :serviceradar_core,
             :cluster_rpc_undef_wait_ms,
             @default_undef_wait_ms
           )
         ) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @default_undef_wait_ms
    end
  end

  defp undef_poll_ms(opts) do
    case Keyword.get(
           opts,
           :undef_poll_ms,
           Application.get_env(
             :serviceradar_core,
             :cluster_rpc_undef_poll_ms,
             @default_undef_poll_ms
           )
         ) do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> @default_undef_poll_ms
    end
  end
end
