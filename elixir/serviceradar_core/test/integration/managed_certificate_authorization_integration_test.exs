defmodule ServiceRadar.NATS.ManagedCertificateAuthorizationIntegrationTest do
  @moduledoc """
  Proves the central certificate authorizer over a real Gnat exchange.

  The broker is a local process with no authorization and no auth callout.
  Readiness only means this process subscribed and loaded a snapshot.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
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
    on_exit(fn -> restore_connection(previous) end)

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
    assert %{ready: true, reason: nil, auth_mode: "static_mtls"} = await_ready()

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
end
