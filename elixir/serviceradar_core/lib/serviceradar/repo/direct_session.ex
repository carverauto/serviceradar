defmodule ServiceRadar.Repo.DirectSession do
  @moduledoc """
  One dedicated database session that bypasses the CNPG pooler.

  `ServiceRadar.Repo` may connect through a transaction-mode pooler, which runs
  each statement outside a transaction on whichever server backend is free. A
  session-level advisory lock taken through it belongs to that backend: the
  unlock can run on another one and miss, and the lock stays with a pooled
  server connection that unrelated clients keep reusing. Session state, such as
  a lock held across several statements, therefore lives on a connection to the
  direct read-write host, which the chart passes as
  `SERVICERADAR_COORDINATOR_DB_HOST`. Without it, the Repo host is used, which
  is correct when no pooler is deployed.
  """

  alias ServiceRadar.Repo

  @direct_host_env "SERVICERADAR_COORDINATOR_DB_HOST"
  # Postgrex's default `:timeout`, which its connect and handshake timeouts inherit.
  @default_timeout 15_000
  @repo_keys [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :socket_dir,
    :socket,
    :parameters,
    :ssl,
    :ssl_opts,
    :connect_timeout,
    :timeout,
    :ipv6,
    :url
  ]

  @doc "The Repo's connection settings, before the direct host is applied."
  def repo_opts, do: Keyword.take(Repo.config(), @repo_keys)

  @doc "The direct read-write host configured for session-scoped connections."
  def direct_host, do: System.get_env(@direct_host_env)

  @doc "Postgrex options for one session on the direct host."
  def connection_opts do
    repo_opts()
    |> put_host(direct_host())
    |> Keyword.put(:pool_size, 1)
  end

  @doc """
  Runs `fun` with a new direct session and closes it afterwards, which ends the
  backend and releases every session lock it still holds. The session is linked
  to the caller, so it also closes if the caller dies.

  `fun` runs only once the session has connected. Postgrex connects in the
  background, and a statement issued before then waits in the pool's queue,
  which drops it after about four seconds. A connection that legitimately takes
  longer, such as one whose name resolution stalls for five seconds, would fail
  that first statement with a queue timeout. The wait is bounded by the
  session's own connect and handshake timeouts. When the session cannot start
  or connect within them, returns
  `{:error, {:direct_session_unavailable, reason}}`.
  """
  def run(fun) when is_function(fun, 1) do
    tag = make_ref()
    opts = Keyword.put(connection_opts(), :connection_listeners, {[self()], tag})

    case Postgrex.start_link(opts) do
      {:ok, session} ->
        try do
          with :ok <- await_connected(tag, connect_budget(opts)) do
            fun.(session)
          end
        after
          stop(session)
          flush_notifications(tag)
        end

      {:error, reason} ->
        {:error, {:direct_session_unavailable, reason}}
    end
  end

  @doc "Points `opts` at `host`, keeping every other setting; a blank host changes nothing."
  def put_host(opts, nil), do: opts

  def put_host(opts, host) when is_binary(host) do
    host = String.trim(host)

    cond do
      host == "" -> opts
      url = Keyword.get(opts, :url) -> Keyword.put(opts, :url, replace_url_host(url, host))
      true -> Keyword.put(opts, :hostname, host)
    end
  end

  defp replace_url_host(url, host) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: current_host} = parsed when is_binary(current_host) ->
        URI.to_string(%{parsed | host: host})

      _ ->
        url
    end
  end

  defp replace_url_host(url, _host), do: url

  defp await_connected(tag, budget) do
    receive do
      {:connected, _connection, ^tag} -> :ok
    after
      budget -> {:error, {:direct_session_unavailable, :connect_timeout}}
    end
  end

  # Postgrex bounds one connection attempt by its connect timeout, which covers
  # name resolution and TCP, and then by its handshake timeout. Both default to
  # the query timeout.
  defp connect_budget(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    Keyword.get(opts, :connect_timeout, timeout) + Keyword.get(opts, :handshake_timeout, timeout)
  end

  defp flush_notifications(tag) do
    receive do
      {_event, _connection, ^tag} -> flush_notifications(tag)
    after
      0 -> :ok
    end
  end

  defp stop(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _ -> :ok
  end
end
