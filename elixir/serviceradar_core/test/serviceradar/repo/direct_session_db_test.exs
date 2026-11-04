defmodule ServiceRadar.Repo.DirectSessionDbTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  @moduletag :integration

  # Longer than the roughly four seconds a statement waits in a new session's
  # pool queue before being dropped, and shorter than the 15 s connect and
  # handshake timeouts, so the connection itself still succeeds.
  @connect_delay 6_000

  # A session whose connection is slow to establish, for instance because name
  # resolution stalls, must still run its first statement once it connects.
  test "a session runs its first statement after a slow connect" do
    route_repo_through_delaying_proxy!(@connect_delay)
    started = System.monotonic_time(:millisecond)

    assert {:ok, %Postgrex.Result{rows: [[1]]}} =
             DirectSession.run(&Postgrex.query(&1, "SELECT 1", []))

    assert System.monotonic_time(:millisecond) - started >= @connect_delay
  end

  defp route_repo_through_delaying_proxy!(delay) do
    env = Application.get_env(:serviceradar_core, Repo)
    upstream = URI.parse(Keyword.fetch!(env, :url))
    on_exit(fn -> Application.put_env(:serviceradar_core, Repo, env) end)

    port = start_delaying_proxy!(upstream.host, upstream.port, delay)
    url = URI.to_string(%{upstream | host: "127.0.0.1", port: port})

    # Certificate verification keeps naming the database host, not the proxy.
    ssl =
      case Keyword.get(env, :ssl) do
        opts when is_list(opts) ->
          Keyword.put_new(opts, :server_name_indication, String.to_charlist(upstream.host))

        other ->
          other
      end

    Application.put_env(
      :serviceradar_core,
      Repo,
      env |> Keyword.put(:url, url) |> Keyword.put(:ssl, ssl)
    )
  end

  # Accepts one connection and forwards it to the database only after `delay`.
  defp start_delaying_proxy!(host, port, delay) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, listen_port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listener)
      Process.sleep(delay)
      {:ok, server} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: true])
      :ok = :inet.setopts(client, active: true)
      relay(client, server)
    end)

    listen_port
  end

  defp relay(client, server) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(server, data)
        relay(client, server)

      {:tcp, ^server, data} ->
        :gen_tcp.send(client, data)
        relay(client, server)

      {:tcp_closed, _socket} ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)
    end
  end
end
