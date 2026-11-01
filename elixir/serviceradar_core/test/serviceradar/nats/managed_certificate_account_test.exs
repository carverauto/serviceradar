defmodule ServiceRadar.NATS.ManagedCertificateAccountTest do
  @moduledoc """
  Bootstrap accepts only the deployment NATS account. Readiness stays unready
  when the stored account disagrees, and that request is denied with no user JWT.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorizer
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration

  setup do
    previous = Application.get_env(:serviceradar, :nats_account_name)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:serviceradar, :nats_account_name)
      else
        Application.put_env(:serviceradar, :nats_account_name, previous)
      end
    end)

    :ok
  end

  test "refuses bootstrap when the deployment account is missing or unusable" do
    actor = actor()

    Application.delete_env(:serviceradar, :nats_account_name)
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, "")
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, "not an account")
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, :EDGE)
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)
  end

  test "refuses a requested account other than the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")

    assert {:error, :nats_account_mismatch} = Configuration.bootstrap("OTHER", actor())
  end

  test "rejects an illegal account name before the deployment check" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    assert {:error, :invalid_account_name} = Configuration.bootstrap("not an account", actor())

    Application.delete_env(:serviceradar, :nats_account_name)
    assert {:error, :invalid_account_name} = Configuration.bootstrap("not an account", actor())
  end

  test "denies bootstrap before account checks when permission is missing" do
    Application.delete_env(:serviceradar, :nats_account_name)

    assert {:error, :forbidden} = Configuration.bootstrap("EDGE", actor([]))
  end

  test "reports ready when the stored account is the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: true,
             reason: nil
           }
  end

  test "stays unready when the stored account disagrees with the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "OTHER")

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "nats_account_mismatch"
           }

    Application.delete_env(:serviceradar, :nats_account_name)

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "nats_account_mismatch"
           }
  end

  test "keeps an earlier unreadiness reason" do
    Application.put_env(:serviceradar, :nats_account_name, "OTHER")

    assert readiness(%{config: nil, reason: "not_configured"}) == %{
             auth_mode: nil,
             account_name: nil,
             ready: false,
             reason: "not_configured"
           }

    assert readiness(%{ready_state("EDGE") | reason: "connecting"}) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "connecting"
           }
  end

  test "reports no account when the authorizer process is down" do
    assert Authorizer.readiness() == %{
             auth_mode: nil,
             account_name: nil,
             ready: false,
             reason: "authorizer_unavailable"
           }
  end

  test "denies an authorization request when the stored account is not the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "OTHER")
    denied = authorize_request("EDGE")
    assert denied.claims["nats"]["type"] == "authorization_response"
    assert denied.claims["nats"]["error"] == "nats_account_mismatch"
    refute Map.has_key?(denied.claims["nats"], "jwt")
    assert denied.sessions == %{}

    Application.delete_env(:serviceradar, :nats_account_name)
    unset = authorize_request("EDGE")
    assert unset.claims["nats"]["error"] == "nats_account_mismatch"
    refute Map.has_key?(unset.claims["nats"], "jwt")
    assert unset.sessions == %{}
  end

  test "signs the deployment account when it matches the stored account" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    allowed = authorize_request("EDGE")
    refute Map.has_key?(allowed.claims["nats"], "error")

    user = verify_response(allowed.claims["nats"]["jwt"], allowed.issuer_nkey)
    assert user["aud"] == "EDGE"
    assert user["sub"] == allowed.user_nkey
    assert user["name"] == allowed.fingerprint
    assert user["nats"]["type"] == "user"
    assert user["nats"]["pub"]["allow"] == ["metrics.example.>"]
    assert user["nats"]["sub"]["allow"] == ["events.example.>"]
    assert user["exp"] == allowed.expires_at

    assert [{_key, session}] = Map.to_list(allowed.sessions)
    assert session.fingerprint == allowed.fingerprint
    assert session.expires_at == allowed.expires_at
    assert Enum.sort(Map.keys(session)) == [:expires_at, :fingerprint]
  end

  test "uses the shipped hub account and rejects the local leaf account name" do
    assert Configuration.deployment_account() == "SERVICERADAR"
    assert {:error, :nats_account_mismatch} = Configuration.bootstrap("EDGE", actor())
  end

  defp actor(permissions \\ ["settings.edge.manage"]) do
    %{permissions: MapSet.new(permissions)}
  end

  defp ready_state(account) do
    %{config: %{auth_mode: "static_mtls", account_name: account}, reason: nil}
  end

  defp readiness(state) do
    assert {:reply, status, ^state} =
             Authorizer.handle_call(:readiness, {self(), make_ref()}, state)

    status
  end

  defp authorize_request(stored_account) do
    issuer = Token.new_key(:account)
    {:ok, signer} = NKEYS.Keypair.from_seed(issuer.seed)
    user = Token.new_key(:user)
    server = server_keypair()
    leaf = leaf_certificate()
    request = authorization_request(server, issuer.public_key, user.public_key, leaf.pem)
    connection = publish_capture()
    snapshot = allowing_snapshot(leaf.fingerprint)

    state = %{
      config: %{
        auth_mode: "static_mtls",
        account_name: stored_account,
        issuer_nkey: issuer.public_key
      },
      signer: signer,
      snapshot: snapshot,
      subscription: {connection, 1},
      sessions: %{}
    }

    assert {:noreply, next} =
             Authorizer.handle_info(
               {:msg,
                %{
                  topic: "$SYS.REQ.USER.AUTH",
                  body: request,
                  reply_to: "reply.example",
                  gnat: connection
                }},
               state
             )

    assert_receive {:published, "reply.example", token}

    %{
      claims: verify_response(token, issuer.public_key),
      sessions: next.sessions,
      issuer_nkey: issuer.public_key,
      user_nkey: user.public_key,
      fingerprint: leaf.fingerprint,
      expires_at: DateTime.to_unix(snapshot.valid_until)
    }
  end

  defp publish_capture do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:capture_ready, self()})

        receive do
          {:"$gen_call", from, {:pub, topic, message, _opts}} ->
            send(parent, {:published, topic, message})
            GenServer.reply(from, :ok)
        after
          2_000 -> send(parent, :capture_timeout)
        end
      end)

    assert_receive {:capture_ready, ^pid}
    pid
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
    seed = Base.encode32(<<bytes::binary, NKEYS.CRC.compute(bytes)::little-16>>, padding: false)
    {:ok, key} = NKEYS.Keypair.from_seed(seed)
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
      fingerprint: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower),
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp allowing_snapshot(fingerprint) do
    now = DateTime.utc_now()
    generated = DateTime.shift(now, second: -1)
    valid_until = DateTime.shift(now, second: 20)
    component_id = "edge-component-01"

    %{
      version: 1,
      generated_at: generated,
      valid_until: valid_until,
      components: [%{component_id: component_id, blocked: false, generation: 1}],
      certificates: [
        %{
          fingerprint: fingerprint,
          component_id: component_id,
          generation: 1,
          not_before: DateTime.shift(now, minute: -1),
          not_after: DateTime.shift(now, hour: 1)
        }
      ],
      revocations: [],
      nats_permissions: %{
        fingerprint => %{
          publish: ["metrics.example.>"],
          subscribe: ["events.example.>"]
        }
      }
    }
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

  defp raw_public_key(encoded, prefix_byte) do
    {:ok, <<^prefix_byte, key::binary-size(32), _crc::little-16>>} =
      Base.decode32(encoded, padding: false)

    key
  end
end
