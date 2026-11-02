defmodule ServiceRadar.Security.PeerCertificateDistributionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.PeerCertificatePolicy, as: Policy
  alias ServiceRadar.Security.PeerCertificatePolicyRefresh, as: Refresh

  @moduletag :cluster

  @tag :tmp_dir
  test "pinned OTP verification process owns only its ERTS TLS connection", %{tmp_dir: dir} do
    assert {_output, 0} = System.cmd("epmd", ["-daemon"])
    {:ok, _} = Application.ensure_all_started(:ssl)
    tasks = start_supervised!(Task.Supervisor)
    responses = start_supervised!({Agent, fn -> %{} end})
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    policy_key_file = Path.join(dir, "policy-key.pub")
    File.write!(policy_key_file, Base.encode64(public_key))
    https = certificate()
    https_port = https_origin(tasks, https.server_config, responses)

    refresh = [
      public_key_file: policy_key_file,
      interval: 100,
      http_options: [proxy: nil, cacerts: Keyword.fetch!(https.client_config, :cacerts)]
    ]

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
      |> Enum.map(fn {name, cert} ->
        url = "https://localhost:#{https_port}/#{name}"
        start_tls_peer(name, cert.server_config, ca_file, dir, Keyword.put(refresh, :url, url))
      end)

    [hub, outbound, inbound, control] = peers
    [_hub_fp, outbound_fp, inbound_fp, control_fp] = fingerprints

    # No ERTS connection is available to fetch bootstrap policy. HTTPS must
    # restore admission independently, including after the policy store restarts.
    refute peer_call(hub, Node, :connect, [elem(outbound, 1)])

    Enum.each(peers, fn peer ->
      serve_policy(responses, peer, snapshot(fingerprints, 30_000), private_key)
      assert eventually(fn -> peer_call(peer, Policy, :status, []).fresh end)
    end)

    assert true == peer_call(hub, Node, :connect, [elem(outbound, 1)])
    assert true == peer_call(inbound, Node, :connect, [elem(hub, 1)])
    assert true == peer_call(hub, Node, :connect, [elem(control, 1)])
    assert %{active: 3} = peer_call(hub, Policy, :status, [])

    for fp <- [outbound_fp, inbound_fp, control_fp] do
      assert %{
               admission: :allowed,
               active: 1,
               closing: 0,
               failed: 0,
               generated_at: %DateTime{},
               valid_until: %DateTime{}
             } =
               peer_call(hub, Policy, :peer_status, [fp])
    end

    # Only the hub learns revocation. It must terminate both its outgoing and
    # incoming sessions while preserving the control link and every peer VM.
    serve_policy(responses, hub, snapshot([control_fp], 20_000), private_key)
    assert eventually(fn -> peer_call(hub, Node, :list, [:connected]) == [elem(control, 1)] end)

    for fp <- [outbound_fp, inbound_fp] do
      assert eventually(fn ->
               match?(
                 %{admission: :denied, fresh: true, active: 0, closing: 0, failed: 0},
                 peer_call(hub, Policy, :peer_status, [fp])
               )
             end)
    end

    assert %{admission: :allowed, active: 1} = peer_call(hub, Policy, :peer_status, [control_fp])
    Enum.each(peers, fn peer -> assert true == peer_call(peer, :erlang, :is_alive, []) end)

    assert elem(control, 1) ==
             peer_call(hub, :erpc, :call, [elem(control, 1), :erlang, :node, []])

    refute peer_call(hub, Node, :connect, [elem(outbound, 1)])
    refute peer_call(inbound, Node, :connect, [elem(hub, 1)])

    # An unsigned permission expansion must not reopen revoked node identities.
    {_wrong_public, wrong_private} = :crypto.generate_key(:eddsa, :ed25519)
    serve_policy(responses, hub, snapshot(fingerprints, 20_000), wrong_private)

    assert eventually(fn ->
             peer_call(hub, Refresh, :status, [Refresh]).last_error ==
               {:error, :invalid_signed_policy}
           end)

    refute peer_call(hub, Node, :connect, [elem(outbound, 1)])

    serve_policy(responses, hub, snapshot([control_fp], 300), private_key)
    assert eventually(fn -> peer_call(hub, Node, :list, [:connected]) == [] end)

    assert eventually(fn ->
             match?(
               %{admission: :stale, fresh: false, active: 0, closing: 0, failed: 0},
               peer_call(hub, Policy, :peer_status, [control_fp])
             )
           end)

    assert true == peer_call(hub, :erlang, :is_alive, [])
    assert true == peer_call(control, :erlang, :is_alive, [])
    serve_policy(responses, hub, snapshot(fingerprints, 20_000), private_key)
    assert eventually(fn -> peer_call(hub, Policy, :status, []).fresh end)
    assert true == peer_call(hub, Node, :connect, [elem(control, 1)])

    old_store = peer_call(hub, Process, :whereis, [Policy])

    peer_call(hub, Code, :eval_string, [
      "Process.exit(Process.whereis(ServiceRadar.Security.PeerCertificatePolicy), :kill)"
    ])

    assert eventually(fn ->
             try do
               peer_call(hub, Process, :whereis, [Policy]) != old_store and
                 peer_call(hub, Policy, :status, []).fresh
             catch
               :exit, _ -> false
             end
           end)

    assert true == peer_call(hub, Node, :connect, [elem(control, 1)])
  end

  defp start_tls_peer(name, server_config, ca_file, dir, refresh) do
    cert_file = Path.join(dir, "#{name}.pem")
    key_file = Path.join(dir, "#{name}-key.pem")
    opts_file = Application.app_dir(:serviceradar_core, "priv/managed_ssl_dist.config")

    File.write!(
      cert_file,
      :public_key.pem_encode([
        {:Certificate, Keyword.fetch!(server_config, :cert), :not_encrypted}
      ])
    )

    {key_type, key_der} = Keyword.fetch!(server_config, :key)
    File.write!(key_file, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))

    environment = [
      {"SERVICERADAR_DIST_CERT_FILE", cert_file},
      {"SERVICERADAR_DIST_KEY_FILE", key_file},
      {"SERVICERADAR_DIST_CA_FILE", ca_file},
      {"SERVICERADAR_CERT_POLICY_KEY_FILE", refresh[:public_key_file]},
      {"SERVICERADAR_CERT_POLICY_URL", refresh[:url]}
    ]

    flags = release_flags(name, opts_file, environment, dir)

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        env:
          Enum.map([{"ERL_FLAGS", flags} | environment], fn {key, value} ->
            {to_charlist(key), to_charlist(value)}
          end),
        wait_boot: 20_000,
        args: [
          ~c"+S",
          ~c"2:2",
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
               {:ok, supervisor} = ServiceRadar.Security.PeerCertificatePolicySupervisor.start_link(opts)
               Process.unlink(supervisor)
               :ok
               """,
               [opts: refresh]
             ])

    {peer, node}
  end

  defp release_flags(name, opts_file, environment, dir) do
    app =
      case name do
        :synthetic_policy_hub -> "serviceradar_core_elx"
        :synthetic_policy_control -> "web-ng"
        _ -> "serviceradar_agent_gateway"
      end

    release_root = Path.join(dir, "release-#{name}")
    priv = Path.join(release_root, "lib/serviceradar_core-0.1.0/priv")
    File.mkdir_p!(priv)
    File.cp!(opts_file, Path.join(priv, "managed_ssl_dist.config"))
    template = Path.expand("../../../../#{app}/rel/env.sh.eex", __DIR__)
    rendered = EEx.eval_file(template, assigns: [release: %{name: name}])
    script = Path.join(release_root, "env.sh")
    File.write!(script, rendered <> ~s(\nprintf '\nMANAGED_FLAGS=%s\n' "$ERL_FLAGS"\n))

    assert {output, 0} =
             System.cmd("sh", [script],
               env:
                 environment ++
                   [
                     {"RELEASE_ROOT", release_root},
                     {"ERL_FLAGS", ""},
                     {"RELEASE_COOKIE", "synthetic_certificate_policy"}
                   ]
             )

    "MANAGED_FLAGS=" <> flags =
      output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "MANAGED_FLAGS="))

    flags
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

  defp serve_policy(responses, {_peer, node}, snapshot, private_key) do
    path = "/" <> (node |> Atom.to_string() |> String.split("@") |> hd())
    payload = Jason.encode!(snapshot)

    signature =
      :crypto.sign(:eddsa, :none, "serviceradar.certificate-policy.v1\0" <> payload, [
        private_key,
        :ed25519
      ])

    body = Jason.encode!(%{payload: Base.encode64(payload), signature: Base.encode64(signature)})
    Agent.update(responses, &Map.put(&1, path, body))
  end

  defp https_origin(tasks, server_options, responses) do
    {:ok, listener} =
      :ssl.listen(0, server_options ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    Task.Supervisor.start_child(tasks, fn -> https_accept(listener, responses) end)
    port
  end

  defp https_accept(listener, responses) do
    case :ssl.transport_accept(listener) do
      {:ok, transport} ->
        {:ok, socket} = :ssl.handshake(transport, 2_000)
        {:ok, request} = :ssl.recv(socket, 0, 2_000)
        ["GET", path | _] = String.split(request, " ")
        body = Agent.get(responses, &Map.get(&1, path))
        {status, body} = if body, do: {200, body}, else: {503, "unavailable"}

        :ok =
          :ssl.send(
            socket,
            "HTTP/1.1 #{status} OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :ssl.close(socket)
        https_accept(listener, responses)

      {:error, :closed} ->
        :ok
    end
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
