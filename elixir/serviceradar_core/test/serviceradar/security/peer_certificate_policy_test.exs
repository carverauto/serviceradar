defmodule ServiceRadar.Security.PeerCertificatePolicyTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.PeerCertificatePolicy, as: Policy

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    tasks = start_supervised!(Task.Supervisor)

    store =
      start_supervised!(
        Supervisor.child_spec({Policy, [name: nil, task_supervisor: tasks]}, restart: :temporary)
      )

    %{tasks: tasks, store: store}
  end

  test "real SSL sockets close selectively and on policy expiry", %{tasks: tasks, store: store} do
    a = certificates()
    b = certificates()
    fp_a = Policy.fingerprint(Keyword.fetch!(a.server_config, :cert))
    fp_b = Policy.fingerprint(Keyword.fetch!(b.server_config, :cert))
    assert {:error, :policy_unavailable} = Policy.authorize(fp_a, store)
    assert :ok = Policy.apply_snapshot(snapshot([fp_a, fp_b], 20_000), store)
    port_a = peer(tasks, a.server_config, :a)
    port_b = peer(tasks, b.server_config, :b)

    {:ok, socket_a} =
      :ssl.connect(
        ~c"localhost",
        port_a,
        Policy.ssl_options(a.client_config, store: store) ++ [active: false],
        2_000
      )

    {:ok, socket_b} =
      :ssl.connect(
        ~c"localhost",
        port_b,
        Policy.ssl_options(b.client_config, store: store) ++ [active: false],
        2_000
      )

    assert {:ok, _} = Policy.watch_ssl(socket_a, self(), store)
    assert {:ok, _} = Policy.watch_ssl(socket_b, self(), store)
    assert :ok = :ssl.send(socket_a, "before")
    assert_receive {:payload, :a, "before"}, 1_000
    assert :ok = Policy.apply_snapshot(snapshot([fp_b], 1_500), store)
    assert_receive {:closed, :a}, 2_000
    assert {:error, :certificate_denied} = Policy.authorize(fp_a, store)
    assert :ok = :ssl.send(socket_b, "control")
    assert_receive {:payload, :b, "control"}, 1_000
    assert_receive {:closed, :b}, 3_000
    assert {:error, :policy_unavailable} = Policy.authorize(fp_b, store)
  end

  test "Gnat owner binding closes its actual TLS connection if the policy store dies", %{
    tasks: tasks,
    store: store
  } do
    certs = certificates()
    fp = Policy.fingerprint(Keyword.fetch!(certs.server_config, :cert))
    snapshot = snapshot([fp], 20_000)
    assert :ok = Policy.apply_snapshot(snapshot, store)
    port = peer(tasks, certs.server_config, :gnat, :nats)

    settings =
      Policy.gnat_options(
        %{host: "localhost", port: port, ssl_opts: certs.client_config},
        :synthetic_policy_gnat,
        store
      )

    {:ok, gnat} = Gnat.start_link(settings, name: :synthetic_policy_gnat)
    Process.unlink(gnat)
    on_exit(fn -> if Process.alive?(gnat), do: GenServer.stop(gnat) end)
    assert :ok = Gnat.pub(gnat, "synthetic.policy", "before")
    assert_receive {:payload, :gnat, data}, 1_000
    assert data =~ "CONNECT"
    assert %{active: 1, fresh: true} = Policy.status(store)
    Process.exit(store, :kill)
    assert_receive {:closed, :gnat}, 2_000
    refute Process.alive?(gnat)

    replica =
      start_supervised!(
        Supervisor.child_spec({Policy, [name: nil, task_supervisor: tasks]}, id: :replica)
      )

    assert {:error, :policy_unavailable} = Policy.authorize(fp, replica)
    wire = snapshot |> Jason.encode!() |> Jason.decode!()
    assert :ok = Policy.apply_snapshot(wire, replica)
    assert :ok = Policy.authorize(fp, replica)
  end

  test "policy composition retains an existing verifier veto", %{tasks: tasks, store: store} do
    certs = certificates()
    fp = Policy.fingerprint(Keyword.fetch!(certs.server_config, :cert))
    :ok = Policy.apply_snapshot(snapshot([fp], 20_000), store)
    port = peer(tasks, certs.server_config, :veto)
    owner = self()

    verify = fn _cert, event, state ->
      case event do
        :valid_peer ->
          send(owner, :prior_verifier_called)
          {:fail, :synthetic_veto}

        {:bad_cert, reason} ->
          {:fail, reason}

        {:extension, _} ->
          {:unknown, state}

        _ ->
          {:valid, state}
      end
    end

    opts = Keyword.put(certs.client_config, :verify_fun, {verify, nil})

    assert {:error, _} =
             :ssl.connect(~c"localhost", port, Policy.ssl_options(opts, store: store), 2_000)

    assert_receive :prior_verifier_called
  end

  defp snapshot(fingerprints, milliseconds) do
    now = DateTime.utc_now()

    %{
      version: 1,
      generated_at: now,
      valid_until: DateTime.add(now, milliseconds, :millisecond),
      allowed_fingerprints: fingerprints
    }
  end

  defp certificates do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp peer(tasks, server_opts, id, mode \\ :tls) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    owner = self()
    on_exit(fn -> :gen_tcp.close(listener) end)

    {:ok, _} =
      Task.Supervisor.start_child(tasks, fn ->
        {:ok, tcp} = :gen_tcp.accept(listener)

        if mode == :nats do
          :ok =
            :gen_tcp.send(
              tcp,
              ~s(INFO {"server_id":"SYNTHETIC_POLICY_SERVER","version":"2.14.0","headers":true,"max_payload":1048576,"tls_required":true}\r\n)
            )
        end

        case :ssl.handshake(tcp, server_opts ++ [active: false, mode: :binary], 2_000) do
          {:ok, socket} -> read_peer(socket, owner, id)
          {:error, _} -> :ok
        end
      end)

    port
  end

  defp read_peer(socket, owner, id) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, bytes} ->
        send(owner, {:payload, id, bytes})
        if String.contains?(bytes, "PING\r\n"), do: :ssl.send(socket, "PONG\r\n")
        read_peer(socket, owner, id)

      {:error, :closed} ->
        send(owner, {:closed, id})

      {:error, reason} ->
        send(owner, {:peer_error, id, reason})
    end
  end
end
