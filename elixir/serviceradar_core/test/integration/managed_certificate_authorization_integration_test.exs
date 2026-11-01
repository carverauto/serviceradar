defmodule ServiceRadar.NATS.ManagedCertificateAuthorizationIntegrationTest do
  @moduledoc """
  Proves the central certificate authorizer over a real Gnat exchange.

  The broker is a local process with no authorization and no auth callout.
  Readiness means this process subscribed, loaded a snapshot, and the stored
  account equals the configured deployment account.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle, as: Lifecycle
  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorizer
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration
  alias ServiceRadar.NATS.ManagedCertificateSupervisor

  @moduletag :integration
  @auth_subject "$SYS.REQ.USER.AUTH"
  @account "EDGE"

  @tag timeout: 120_000
  test "signed grants follow stored permissions and deny a certificate without them" do
    previous = Application.get_env(:serviceradar_core, Connection)
    previous_account = Application.get_env(:serviceradar, :nats_account_name)
    on_exit(fn -> restore_connection(previous) end)
    on_exit(fn -> restore_account(previous_account) end)
    Application.put_env(:serviceradar, :nats_account_name, @account)

    listen_port = free_port()
    assert listen_port != 4222
    log_path = Path.join(System.tmp_dir!(), "managed-cert-auth-#{listen_port}.log")
    args = ["-a", "127.0.0.1", "-p", Integer.to_string(listen_port), "-l", log_path]
    refute Enum.any?(args, &String.contains?(&1, "auth_callout"))

    executable = nats_server!()
    broker = open_broker(executable, args)
    {:os_pid, os_pid} = Port.info(broker, :os_pid)
    on_exit(fn -> stop_broker(broker, executable, os_pid) end)
    await_broker(listen_port)

    actor =
      :component_certificate_test
      |> SystemActor.system()
      |> Map.put(:permissions, MapSet.new(["settings.edge.manage"]))

    opts = [actor: actor]
    id = "example-core-#{System.unique_integer([:positive])}"
    leaf = leaf_certificate()

    assert {:ok, _component} =
             Authority.enroll_component(
               %{component_id: id, component_type: "core", partition_id: "example-partition"},
               opts
             )

    now = DateTime.truncate(DateTime.utc_now(), :second)

    assert {:ok, _certificate} =
             Authority.record_issuance(
               id,
               %{
                 fingerprint: leaf.fingerprint,
                 issuer_fingerprint: fingerprint("invented-issuer"),
                 serial_number: "41",
                 role: "client",
                 expected_generation: 1,
                 not_before: DateTime.shift(now, minute: -1),
                 not_after: DateTime.shift(now, hour: 1)
               },
               opts
             )

    assert {:ok, %{issuer_nkey: issuer_nkey, account_name: @account, auth_mode: "static_mtls"}} =
             Configuration.bootstrap(@account, actor)

    assert {:ok, before} = Authority.snapshot()
    assert leaf.fingerprint in before.allowed_fingerprints
    refute Map.has_key?(before.nats_permissions, leaf.fingerprint)

    Application.put_env(:serviceradar_core, Connection,
      host: "127.0.0.1",
      port: listen_port,
      tls: false
    )

    start_supervised_authorizer!()

    assert %{ready: true, reason: nil, auth_mode: "static_mtls", account_name: @account} =
             await_ready()

    %{public_key: user_nkey} = Token.new_key(:user)
    server = server_keypair()
    request = authorization_request(server, issuer_nkey, user_nkey, leaf.pem)
    {:ok, client} = Gnat.start_link(%{host: "127.0.0.1", port: listen_port})
    on_exit(fn -> stop_client(client) end)

    assert {:ok, denied} = request_decision(client, request, issuer_nkey)
    assert denied["nats"]["type"] == "authorization_response"
    assert denied["nats"]["error"] == "certificate not authorized"
    refute Map.has_key?(denied["nats"], "jwt")

    permissions = %{
      "publish" => ["example.events.>"],
      "subscribe" => [],
      "publish_deny" => ["example.events.private.>"],
      "subscribe_deny" => ["$SYS.>"]
    }

    assert {:ok, _} = Authority.set_infrastructure_permissions(id, 1, permissions, opts)
    assert {:ok, allowed} = await_allow(client, request, issuer_nkey)
    user = verify_response(allowed["nats"]["jwt"], issuer_nkey)
    assert user["aud"] == @account
    assert user["name"] == leaf.fingerprint
    assert user["sub"] == user_nkey
    assert user["nats"]["type"] == "user"

    assert user["nats"]["pub"] == %{
             "allow" => ["example.events.>"],
             "deny" => ["example.events.private.>"]
           }

    assert user["nats"]["sub"] == %{"deny" => [">"]}

    issued = System.system_time(:second)
    assert user["exp"] > issued and user["exp"] < issued + 60
  end

  @tag timeout: 180_000
  test "hub observes presented leaf certificates and revocation drops only that leaf" do
    previous = Application.get_env(:serviceradar_core, Connection)
    previous_account = Application.get_env(:serviceradar, :nats_account_name)
    on_exit(fn -> restore_connection(previous) end)
    on_exit(fn -> restore_account(previous_account) end)
    Application.put_env(:serviceradar, :nats_account_name, @account)

    actor =
      :component_certificate_test
      |> SystemActor.system()
      |> Map.put(:permissions, MapSet.new(["settings.edge.manage"]))

    opts = [actor: actor]

    assert {:ok, %{issuer_nkey: issuer, auth_nkey: auth, system_nkey: system}} =
             Configuration.bootstrap(@account, actor)

    assert {:ok, %{system_seed: system_seed}} = Configuration.credentials()

    dir = Path.join(System.tmp_dir!(), "managed-leaf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    ca = issue_material!(dir, "ca", nil, nil)

    hub =
      issue_material!(
        dir,
        "hub",
        ca,
        "subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n"
      )

    left =
      issue_material!(
        dir,
        "left",
        ca,
        "subjectAltName=DNS:left.synthetic.example\nextendedKeyUsage=clientAuth\n"
      )

    right =
      issue_material!(
        dir,
        "right",
        ca,
        "subjectAltName=DNS:right.synthetic.example\nextendedKeyUsage=clientAuth\n"
      )

    client_port = free_port()
    leaf_port = free_port()
    log_path = Path.join(dir, "hub.log")
    hub_config = Path.join(dir, "hub.conf")

    File.write!(hub_config, hub_config(client_port, leaf_port, issuer, auth, system, hub, ca))

    executable = nats_server!()
    broker = open_broker(executable, ["-c", hub_config, "-l", log_path])
    {:os_pid, os_pid} = Port.info(broker, :os_pid)
    on_exit(fn -> stop_broker(broker, executable, os_pid) end)
    await_broker(client_port)

    left_component = enroll_leaf!("left", opts)
    right_component = enroll_leaf!("right", opts)
    record_leaf!(left_component, left, opts)
    record_leaf!(right_component, right, opts)
    activate_upstream!(left_component, left.fingerprint, opts)

    Application.put_env(:serviceradar_core, Connection,
      host: "127.0.0.1",
      port: client_port,
      tls: false
    )

    start_supervised_authorizer!()
    assert %{ready: true, reason: nil, account_name: @account} = await_ready()

    {:ok, sys} =
      Gnat.start_link(%{
        host: "127.0.0.1",
        port: client_port,
        nkey_seed: fn -> system_seed end,
        auth_required: true
      })

    on_exit(fn -> stop_client(sys) end)

    left_spoke = start_spoke!(executable, dir, "spoke-left", leaf_port, left, ca)
    right_spoke = start_spoke!(executable, dir, "spoke-right", leaf_port, right, ca)
    on_exit(fn -> stop_broker(left_spoke.broker, executable, left_spoke.os_pid) end)
    on_exit(fn -> stop_broker(right_spoke.broker, executable, right_spoke.os_pid) end)

    assert await_leaf_members(sys, [left.fingerprint, right.fingerprint], log_path)
    assert await_upstream_observation(left_component.component_id, opts)

    {:ok, bridge_left} = Gnat.start_link(%{host: "127.0.0.1", port: left_spoke.port})
    {:ok, bridge_right} = Gnat.start_link(%{host: "127.0.0.1", port: right_spoke.port})
    on_exit(fn -> stop_client(bridge_left) end)
    on_exit(fn -> stop_client(bridge_right) end)
    {:ok, _sid} = Gnat.sub(bridge_right, self(), "example.managed.leaf")
    Process.sleep(300)
    :ok = Gnat.pub(bridge_left, "example.managed.leaf", "before")
    assert_receive {:msg, %{body: "before", topic: "example.managed.leaf"}}, 5_000

    assert {:ok, _} =
             Authority.revoke_certificate(left.fingerprint, "operator-revoke", opts)

    assert {:error, :certificate_revoked} =
             Authority.record_issuance(
               left_component.component_id,
               leaf_issuance(left_component, left),
               opts
             )

    assert await_leaf_members(sys, [right.fingerprint], log_path, [left.fingerprint])
    assert stable_leaf_split(sys, left.fingerprint, right.fingerprint, log_path)
    :ok = Gnat.pub(bridge_left, "example.managed.leaf", "after")
    refute_receive {:msg, %{body: "after", topic: "example.managed.leaf"}}, 1_000
    assert right.fingerprint in leaf_fingerprints!(sys, log_path)
  end

  defp start_supervised_authorizer! do
    {:ok, _} = Application.ensure_all_started(:gnat)
    assert {:ok, pid} = ManagedCertificateSupervisor.start_link([])
    on_exit(fn -> stop_supervisor(pid) end)
    pid
  end

  defp await_ready(attempts \\ 50) do
    status = Authorizer.readiness()

    cond do
      status.ready ->
        status

      attempts == 0 ->
        flunk("authorizer did not become ready: #{inspect(status)}")

      true ->
        Process.sleep(500)
        await_ready(attempts - 1)
    end
  end

  defp await_allow(client, request, issuer_nkey, attempts \\ 40) do
    case request_decision(client, request, issuer_nkey) do
      {:ok, %{"nats" => %{"jwt" => _}} = claims} ->
        {:ok, claims}

      {:ok, %{"nats" => %{"error" => _}}} when attempts > 0 ->
        Process.sleep(250)
        await_allow(client, request, issuer_nkey, attempts - 1)

      other ->
        other
    end
  end

  defp request_decision(client, request, issuer_nkey) do
    case Gnat.request(client, @auth_subject, request, receive_timeout: 5_000) do
      {:ok, %{body: body}} -> {:ok, verify_response(body, issuer_nkey)}
      other -> other
    end
  end

  defp verify_response(token, issuer_nkey) do
    [header, body, signature] = String.split(token, ".")
    {:ok, header_json} = Base.url_decode64(header, padding: false)
    {:ok, body_json} = Base.url_decode64(body, padding: false)
    {:ok, raw_signature} = Base.url_decode64(signature, padding: false)
    assert Jason.decode!(header_json) == %{"typ" => "JWT", "alg" => "ed25519-nkey"}

    assert :crypto.verify(
             :eddsa,
             :none,
             header <> "." <> body,
             raw_signature,
             [raw_public_key(issuer_nkey, 0), :ed25519]
           )

    Jason.decode!(body_json)
  end

  defp authorization_request(server, issuer_nkey, user_nkey, leaf_pem) do
    now = System.system_time(:second)
    header = %{"typ" => "JWT", "alg" => "ed25519-nkey"}

    claims = %{
      "iss" => NKEYS.Keypair.public_key(server),
      "sub" => issuer_nkey,
      "aud" => "nats-authorization-request",
      "iat" => now,
      "exp" => now + 30,
      "nats" => %{
        "type" => "authorization_request",
        "version" => 2,
        "server_id" => %{"id" => NKEYS.Keypair.public_key(server)},
        "client_info" => %{"id" => 7},
        "user_nkey" => user_nkey,
        "client_tls" => %{"verified_chains" => [[leaf_pem]]}
      }
    }

    encoded_header = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    encoded_body = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    unsigned = encoded_header <> "." <> encoded_body
    signature = server |> NKEYS.Keypair.sign(unsigned) |> Base.url_encode64(padding: false)
    unsigned <> "." <> signature
  end

  # nkeys 0.3.1 new_server/0 returns an empty seed. The request signer uses the
  # same seed wire format as CertificateAuthorizationToken.new_key/1, with the
  # server prefix, and stays in this test.
  defp server_keypair do
    prefix = 13
    bytes = <<18::5, prefix::5, 0::6, :crypto.strong_rand_bytes(32)::binary>>
    crc = NKEYS.CRC.compute(bytes)
    seed = Base.encode32(<<bytes::binary, crc::little-16>>, padding: false)
    {:ok, key} = NKEYS.Keypair.from_seed(seed)
    key
  end

  defp raw_public_key(encoded, prefix_byte) do
    {:ok, <<^prefix_byte, key::binary-size(32), _crc::little-16>>} =
      Base.decode32(encoded, padding: false)

    key
  end

  defp leaf_certificate do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"client.example.com"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: alg, intermediates: [], peer: alg},
        client_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]}
      })

    der = Keyword.fetch!(data.client_config, :cert)

    %{
      fingerprint: fingerprint(der),
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp fingerprint(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp nats_server! do
    staged =
      case System.fetch_env("TEST_TMPDIR") do
        {:ok, dir} -> Path.wildcard(Path.join(dir, "external/*/nats-server"))
        :error -> []
      end

    case staged do
      [path | _] ->
        path

      [] ->
        System.find_executable("nats-server") ||
          flunk("nats-server is not staged and not on PATH")
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    if port == 4222, do: free_port(), else: port
  end

  defp open_broker(executable, args) do
    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])
  end

  defp await_broker(port, attempts \\ 50) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} when attempts > 0 ->
        Process.sleep(100)
        await_broker(port, attempts - 1)

      other ->
        flunk("local broker did not accept connections: #{inspect(other)}")
    end
  end

  defp stop_client(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Gnat.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_supervisor(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp stop_broker(broker, executable, os_pid) do
    if is_integer(os_pid) and is_binary(executable) do
      _ = System.cmd(executable, ["--signal", "quit=#{os_pid}"], stderr_to_stdout: true)
    end

    if is_port(broker) and Port.info(broker) do
      receive do
        {^broker, {:exit_status, _status}} -> :ok
      after
        5_000 -> Port.close(broker)
      end
    end
  end

  defp restore_connection(nil), do: Application.delete_env(:serviceradar_core, Connection)

  defp restore_connection(value), do: Application.put_env(:serviceradar_core, Connection, value)

  defp restore_account(nil), do: Application.delete_env(:serviceradar, :nats_account_name)

  defp restore_account(value), do: Application.put_env(:serviceradar, :nats_account_name, value)

  defp issue_material!(dir, name, nil, _extension) do
    openssl!(
      [
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:prime256v1",
        "-nodes",
        "-keyout",
        "#{name}.key",
        "-out",
        "#{name}.pem",
        "-days",
        "2",
        "-subj",
        "/CN=synthetic-managed-ca"
      ],
      dir
    )

    pem = File.read!(Path.join(dir, "#{name}.pem"))
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)

    %{
      pem: pem,
      der: der,
      key: Path.join(dir, "#{name}.key"),
      cert: Path.join(dir, "#{name}.pem"),
      fingerprint: fingerprint(der)
    }
  end

  defp issue_material!(dir, name, ca, extension) do
    openssl!(
      [
        "req",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:prime256v1",
        "-nodes",
        "-keyout",
        "#{name}.key",
        "-out",
        "#{name}.csr",
        "-subj",
        "/CN=#{name}.synthetic.example"
      ],
      dir
    )

    File.write!(Path.join(dir, "#{name}.ext"), "basicConstraints=CA:FALSE\n#{extension}")

    openssl!(
      [
        "x509",
        "-req",
        "-in",
        "#{name}.csr",
        "-CA",
        ca.cert,
        "-CAkey",
        ca.key,
        "-CAserial",
        "ca.srl",
        "-CAcreateserial",
        "-out",
        "#{name}.pem",
        "-days",
        "2",
        "-extfile",
        "#{name}.ext"
      ],
      dir
    )

    pem = File.read!(Path.join(dir, "#{name}.pem"))
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)

    %{
      pem: pem,
      der: der,
      key: Path.join(dir, "#{name}.key"),
      cert: Path.join(dir, "#{name}.pem"),
      fingerprint: fingerprint(der)
    }
  end

  defp openssl!(args, dir) do
    executable = System.find_executable("openssl") || flunk("openssl is not on PATH")

    case System.cmd(executable, args, cd: dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("openssl failed (#{status}): #{output}")
    end
  end

  defp hub_config(client_port, leaf_port, issuer, auth, system, hub, ca) do
    """
    server_name: hub-synthetic
    listen: 127.0.0.1:#{client_port}
    accounts {
      SYS: {
        users: [
          {nkey: #{Jason.encode!(system)}, permissions: {publish: {allow: ["$SYS.REQ.SERVER.*.CONNZ", "$SYS.REQ.SERVER.*.KICK"]}, subscribe: {allow: ["_INBOX.>"]}}}
        ]
      }
      AUTH: {
        users: [
          {nkey: #{Jason.encode!(auth)}, permissions: {subscribe: ["$SYS.REQ.USER.AUTH"], publish: ["$SYS._INBOX.>"]}}
        ]
      }
      EDGE: {}
    }
    system_account: SYS
    authorization: {auth_callout: {issuer: #{Jason.encode!(issuer)}, account: AUTH, auth_users: [#{Jason.encode!(auth)}, #{Jason.encode!(system)}]}}
    leafnodes {
      listen: 127.0.0.1:#{leaf_port}
      tls {
        cert_file: #{Jason.encode!(hub.cert)}
        key_file: #{Jason.encode!(hub.key)}
        ca_file: #{Jason.encode!(ca.cert)}
        verify: true
        timeout: 5
      }
    }
    """
  end

  defp enroll_leaf!(name, opts) do
    assert {:ok, component} =
             Authority.enroll_component(
               %{
                 component_id: "#{name}-#{System.unique_integer([:positive])}",
                 component_type: "nats-leaf",
                 partition_id: "example-partition",
                 host_agent_id: "host-#{name}-#{System.unique_integer([:positive])}"
               },
               opts
             )

    component
  end

  defp record_leaf!(component, material, opts) do
    assert {:ok, _} =
             Authority.record_issuance(
               component.component_id,
               leaf_issuance(component, material),
               opts
             )
  end

  defp leaf_issuance(component, material) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    %{
      fingerprint: material.fingerprint,
      issuer_fingerprint: fingerprint("synthetic-issuer"),
      serial_number: "71",
      role: "upstream_client",
      expected_generation: 1,
      host_agent_id: component.host_agent_id,
      not_before: DateTime.shift(now, minute: -1),
      not_after: DateTime.shift(now, hour: 2)
    }
  end

  defp activate_upstream!(component, fingerprint, opts) do
    {:ok, preparing} = Lifecycle.rotate(component.component_id, opts)

    preparing
    |> Ash.Changeset.for_update(
      :progress,
      %{
        status: :installing,
        fingerprints: %{"upstream_client" => fingerprint},
        renew_after: DateTime.shift(DateTime.utc_now(), hour: 1)
      },
      opts
    )
    |> Ash.update!(opts)
    |> Ash.Changeset.for_update(:progress, %{status: :activated}, opts)
    |> Ash.update!(opts)
  end

  defp start_spoke!(executable, dir, name, leaf_port, material, ca) do
    port = free_port()
    config = Path.join(dir, "#{name}.conf")

    File.write!(config, """
    server_name: #{name}
    listen: 127.0.0.1:#{port}
    leafnodes {
      remotes: [
        {
          url: "tls://127.0.0.1:#{leaf_port}"
          tls {
            cert_file: #{Jason.encode!(material.cert)}
            key_file: #{Jason.encode!(material.key)}
            ca_file: #{Jason.encode!(ca.cert)}
          }
        }
      ]
    }
    """)

    broker = open_broker(executable, ["-c", config, "-l", Path.join(dir, "#{name}.log")])
    {:os_pid, os_pid} = Port.info(broker, :os_pid)
    await_broker(port)
    %{broker: broker, os_pid: os_pid, port: port}
  end

  defp await_leaf_members(client, required, log_path, absent \\ [], attempts \\ 40) do
    present =
      case leaf_fingerprints(client) do
        {:ok, found} -> found
        {:error, reason} -> flunk("CONNZ failed: #{inspect(reason)}\n#{log_tail(log_path)}")
      end

    cond do
      Enum.all?(required, &(&1 in present)) and Enum.all?(absent, &(&1 not in present)) ->
        true

      attempts == 0 ->
        flunk(
          "leaf certificates were #{inspect(present)}, wanted #{inspect(required)} without #{inspect(absent)}\n#{log_tail(log_path)}"
        )

      true ->
        Process.sleep(500)
        await_leaf_members(client, required, log_path, absent, attempts - 1)
    end
  end

  defp stable_leaf_split(client, revoked, peer, log_path) do
    Enum.each(1..6, fn _ ->
      assert {:ok, present} = leaf_fingerprints(client)
      refute revoked in present, log_tail(log_path)
      assert peer in present
      Process.sleep(500)
    end)
  end

  defp await_upstream_observation(component_id, opts, attempts \\ 40) do
    {:ok, operation} = Lifecycle.current(component_id, opts)
    receiver = get_in(operation.observed_roles, ["upstream_client", "receiver_id"])

    cond do
      is_binary(receiver) and String.starts_with?(receiver, "nats:") and
          receiver != "nats:hub-synthetic" ->
        true

      attempts == 0 ->
        flunk(
          "upstream certificate was not observed by a hub server: #{inspect(operation && operation.observed_roles)}"
        )

      true ->
        Process.sleep(500)
        await_upstream_observation(component_id, opts, attempts - 1)
    end
  end

  defp leaf_fingerprints!(client, log_path) do
    case leaf_fingerprints(client) do
      {:ok, found} -> found
      {:error, reason} -> flunk("CONNZ failed: #{inspect(reason)}\n#{log_tail(log_path)}")
    end
  end

  defp leaf_fingerprints(client) do
    body = Jason.encode!(%{auth: true, acc: @account, offset: 0, limit: 256})

    case Gnat.request(client, "$SYS.REQ.SERVER.PING.CONNZ", body, receive_timeout: 2_000) do
      {:ok, %{body: response}} ->
        decoded = Jason.decode!(response)

        found =
          for %{"kind" => "Leafnode", "tls_peer_certs" => [%{"cert_sha256" => fingerprint} | _]} <-
                get_in(decoded, ["data", "connections"]) || [],
              do: String.downcase(fingerprint)

        {:ok, found}

      other ->
        {:error, other}
    end
  end

  defp log_tail(path) do
    case File.read(path) do
      {:ok, body} -> String.slice(body, -4_000, 4_000)
      _ -> ""
    end
  end
end
