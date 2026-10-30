defmodule ServiceRadar.Security.PeerCertificateDistributionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.PeerCertificatePolicy, as: Policy

  @moduletag :cluster

  @tag :tmp_dir
  test "pinned OTP verification process owns only its ERTS TLS connection", %{tmp_dir: dir} do
    assert {_output, 0} = System.cmd("epmd", ["-daemon"])
    certs = for _ <- 1..4, do: certificate()
    roots = certs |> Enum.flat_map(&Keyword.fetch!(&1.client_config, :cacerts)) |> Enum.uniq()
    ca_file = Path.join(dir, "roots.pem")

    File.write!(
      ca_file,
      :public_key.pem_encode(Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    )

    fingerprints = Enum.map(certs, &Policy.fingerprint(Keyword.fetch!(&1.server_config, :cert)))

    peers =
      [
        :synthetic_policy_hub,
        :synthetic_policy_outbound,
        :synthetic_policy_inbound,
        :synthetic_policy_control
      ]
      |> Enum.zip(certs)
      |> Enum.map(fn {name, cert} -> start_tls_peer(name, cert.server_config, ca_file, dir) end)

    [hub, outbound, inbound, control] = peers
    [_hub_fp, _outbound_fp, _inbound_fp, control_fp] = fingerprints

    Enum.each(peers, fn {peer, _node} ->
      assert :ok = :peer.call(peer, Policy, :apply_snapshot, [snapshot(fingerprints, 30_000)])
    end)

    assert true == peer_call(hub, Node, :connect, [elem(outbound, 1)])
    assert true == peer_call(inbound, Node, :connect, [elem(hub, 1)])
    assert true == peer_call(hub, Node, :connect, [elem(control, 1)])
    assert %{active: 3} = peer_call(hub, Policy, :status, [])

    # Only the hub learns revocation. It must terminate both its outgoing and
    # incoming sessions while preserving the control link and every peer VM.
    assert :ok = peer_call(hub, Policy, :apply_snapshot, [snapshot([control_fp], 20_000)])
    assert eventually(fn -> peer_call(hub, Node, :list, [:connected]) == [elem(control, 1)] end)
    Enum.each(peers, fn peer -> assert true == peer_call(peer, :erlang, :is_alive, []) end)

    assert elem(control, 1) ==
             peer_call(hub, :erpc, :call, [elem(control, 1), :erlang, :node, []])

    refute peer_call(hub, Node, :connect, [elem(outbound, 1)])
    refute peer_call(inbound, Node, :connect, [elem(hub, 1)])

    assert :ok = peer_call(hub, Policy, :apply_snapshot, [snapshot([control_fp], 300)])
    assert eventually(fn -> peer_call(hub, Node, :list, [:connected]) == [] end)
    assert true == peer_call(hub, :erlang, :is_alive, [])
    assert true == peer_call(control, :erlang, :is_alive, [])
    assert :ok = peer_call(hub, Policy, :apply_snapshot, [snapshot(fingerprints, 20_000)])
    assert true == peer_call(hub, Node, :connect, [elem(control, 1)])
  end

  defp start_tls_peer(name, server_config, ca_file, dir) do
    cert_file = Path.join(dir, "#{name}.pem")
    key_file = Path.join(dir, "#{name}-key.pem")
    opts_file = Path.join(dir, "#{name}-dist.config")

    File.write!(
      cert_file,
      :public_key.pem_encode([
        {:Certificate, Keyword.fetch!(server_config, :cert), :not_encrypted}
      ])
    )

    {key_type, key_der} = Keyword.fetch!(server_config, :key)
    File.write!(key_file, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))

    options =
      Policy.ssl_options(
        [
          certfile: to_charlist(cert_file),
          keyfile: to_charlist(key_file),
          cacertfile: to_charlist(ca_file),
          versions: [:"tlsv1.3"]
        ],
        owner: :verify_process
      )

    term = [server: Keyword.put(options, :fail_if_no_peer_cert, true), client: options]
    File.write!(opts_file, :io_lib.format(~c"~p.~n", [term]))

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        wait_boot: 20_000,
        args: [
          ~c"+S",
          ~c"2:2",
          ~c"-proto_dist",
          ~c"inet_tls",
          ~c"-ssl_dist_optfile",
          to_charlist(opts_file),
          ~c"-setcookie",
          ~c"synthetic_certificate_policy",
          ~c"-kernel",
          ~c"connect_all",
          ~c"false",
          ~c"prevent_overlapping_partitions",
          ~c"false",
          ~c"dist_auto_connect",
          ~c"never"
        ]
      })

    Process.unlink(peer)
    on_exit(fn -> :peer.stop(peer) end)
    assert :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    assert {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    assert {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:logger])
    assert {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:ssl])

    assert {:ok, _bindings} =
             :peer.call(peer, Code, :eval_string, [
               """
               {:ok, tasks} = Task.Supervisor.start_link()
               Process.unlink(tasks)
               {:ok, store} = ServiceRadar.Security.PeerCertificatePolicy.start_link(task_supervisor: tasks)
               Process.unlink(store)
               :ok
               """
             ])

    {peer, node}
  end

  defp peer_call({peer, _node}, module, function, args),
    do: :peer.call(peer, module, function, args)

  defp snapshot(fingerprints, milliseconds) do
    now = DateTime.utc_now()

    %{
      version: 1,
      generated_at: now,
      valid_until: DateTime.add(now, milliseconds, :millisecond),
      allowed_fingerprints: fingerprints
    }
  end

  defp certificate do
    san =
      {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>]}

    eku =
      {:Extension, {2, 5, 29, 37}, false,
       [{1, 3, 6, 1, 5, 5, 7, 3, 1}, {1, 3, 6, 1, 5, 5, 7, 3, 2}]}

    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san, eku]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp eventually(predicate, attempts \\ 60)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.(),
      do: true,
      else:
        (
          Process.sleep(50)
          eventually(predicate, attempts - 1)
        )
  end
end
