defmodule ServiceRadar.NATS.ManagedCertificateAccountTest do
  @moduledoc """
  Bootstrap accepts only the deployment NATS account. Readiness stays unready
  when the stored account disagrees, and that request is denied with no user JWT.
  A granted session names its grant, and the hub scan disconnects a session
  whose grant is not the one its certificate would receive now.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorizer
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration
  alias ServiceRadar.NATS.StaticIdentityGrants

  @builtin_subject [
    {{2, 5, 4, 6}, ~c"US"},
    {{2, 5, 4, 8}, {:utf8String, "EX"}},
    {{2, 5, 4, 7}, {:utf8String, "Example City"}},
    {{2, 5, 4, 10}, {:utf8String, "ExampleOrg"}},
    {{2, 5, 4, 11}, {:utf8String, "Kubernetes"}},
    {{2, 5, 4, 3}, {:utf8String, "example-core"}}
  ]

  # The system connection: one CONNZ page of the given connections, and a
  # recorded, acknowledged KICK.
  defmodule FakeBroker do
    @moduledoc false
    use GenServer

    def start_link(connections),
      do: GenServer.start_link(__MODULE__, connections, name: :serviceradar_certificate_system)

    def kicked(pid), do: GenServer.call(pid, :kicked)

    @impl true
    def init(connections), do: {:ok, %{connections: connections, subscriber: nil, kicked: []}}

    @impl true
    def handle_call({:sub, subscriber, _topic, _opts}, _from, state),
      do: {:reply, {:ok, 1}, %{state | subscriber: subscriber}}

    def handle_call({:unsub, _sid, _opts}, _from, state), do: {:reply, :ok, state}

    def handle_call({:pub, "$SYS.REQ.SERVER.PING.CONNZ", _payload, _opts}, _from, state) do
      page = %{
        "server" => %{"id" => "hub-a"},
        "data" => %{
          "offset" => 0,
          "total" => length(state.connections),
          "connections" => state.connections
        }
      }

      send(state.subscriber, {:msg, %{sid: 1, body: Jason.encode!(page)}})
      {:reply, :ok, state}
    end

    def handle_call({:pub, _subject, _payload, _opts}, _from, state), do: {:reply, :ok, state}

    def handle_call({:request, %{topic: "$SYS.REQ.SERVER.hub-a.KICK"} = request}, _from, state) do
      %{"cid" => cid} = Jason.decode!(request.body)
      send(request.recipient, {:msg, %{topic: "kick-reply", body: ~s({"server":{"id":"hub-a"}})}})
      {:reply, {:ok, "kick-reply"}, %{state | kicked: state.kicked ++ [cid]}}
    end

    def handle_call(:kicked, _from, state), do: {:reply, state.kicked, state}
  end

  setup do
    previous = Application.get_env(:serviceradar, :nats_account_name)
    previous_ttl = Application.get_env(:serviceradar, :nats_certificate_grant_ttl_seconds)
    Application.delete_env(:serviceradar, :nats_certificate_grant_ttl_seconds)

    on_exit(fn ->
      if previous_ttl == nil do
        Application.delete_env(:serviceradar, :nats_certificate_grant_ttl_seconds)
      else
        Application.put_env(:serviceradar, :nats_certificate_grant_ttl_seconds, previous_ttl)
      end

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

    assert user["name"] ==
             allowed.fingerprint <>
               ".bbcf9abc89cd17e12ace4aeb6ca3714f8f89d3360d56b540fc49225582c64703"

    assert user["nats"]["type"] == "user"
    assert user["nats"]["pub"]["allow"] == ["metrics.example.>"]
    assert user["nats"]["sub"]["allow"] == ["events.example.>"]
    assert user["exp"] == allowed.certificate_expires_at

    assert [{_key, session}] = Map.to_list(allowed.sessions)
    assert session.fingerprint == allowed.fingerprint
    assert session.expires_at == user["exp"]
    assert Enum.sort(Map.keys(session)) == [:expires_at, :fingerprint]
  end

  test "grant names match the Go local-leaf callout golden vectors" do
    fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    assert Token.grant_name(fingerprint, %{
             publish: ["metrics.example.>", "telemetry.edge-record.v1.bulk.>"],
             subscribe: ["_INBOX.>"],
             publish_deny: ["metrics.example.private.>"]
           }) ==
             fingerprint <>
               ".0a927de9431ea74d4030390481597ca690d23f9779e0c35944cb79d78eca8033"

    assert Token.grant_name(fingerprint, %{
             publish: ["metrics.example.>"],
             subscribe: ["events.example.>"]
           }) ==
             fingerprint <>
               ".bbcf9abc89cd17e12ace4aeb6ca3714f8f89d3360d56b540fc49225582c64703"

    assert Token.grant_name(fingerprint, %{
             publish: ["events.example.*"],
             subscribe: [],
             subscribe_deny: ["events.example.private"]
           }) ==
             fingerprint <>
               ".88a5e2cd34fdb8076c88999d2853429aab8889d249b3cbc0c63c207d3df8873c"
  end

  test "default grants are jittered around twelve hours independently of policy freshness" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    before = System.system_time(:second)

    expiries =
      for _ <- 1..12 do
        allowed = authorize_request("EDGE", certificate_hours: 24)
        verify_response(allowed.claims["nats"]["jwt"], allowed.issuer_nkey)["exp"]
      end

    after_requests = System.system_time(:second)
    assert Enum.all?(expiries, &(&1 >= before + 34_560 and &1 <= after_requests + 51_840))
    assert length(Enum.uniq(expiries)) > 1
  end

  test "configured grant lifetime does not allow admission with stale or revoked policy" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    Application.put_env(:serviceradar, :nats_certificate_grant_ttl_seconds, 300)
    before = System.system_time(:second)
    allowed = authorize_request("EDGE")
    expires = verify_response(allowed.claims["nats"]["jwt"], allowed.issuer_nkey)["exp"]
    assert expires >= before + 240 and expires <= System.system_time(:second) + 360

    for opts <- [[policy_seconds: -1], [blocked: true]] do
      denied = authorize_request("EDGE", opts)
      assert denied.claims["nats"]["error"] == "certificate not authorized"
      refute Map.has_key?(denied.claims["nats"], "jwt")
      assert denied.sessions == %{}
    end
  end

  test "an adopted infrastructure certificate presenting a built-in subject gets its static block" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    builtin = subject_certificate(@builtin_subject)

    # Static semantics: the empty subscribe allow is every subject.
    {:ok, static_users} =
      StaticIdentityGrants.parse("""
      - user: "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US"
        publish:
          allow: ["metrics.sweep.>"]
          deny: ["$SYS.>"]
        subscribe:
          allow: []
      """)

    granted =
      authorize_request("EDGE",
        certificate: builtin,
        component_type: "core",
        static_users: static_users
      )

    user = verify_response(granted.claims["nats"]["jwt"], granted.issuer_nkey)
    assert user["nats"]["pub"] == %{"allow" => ["metrics.sweep.>"], "deny" => ["$SYS.>"]}
    assert user["nats"]["sub"] == %{"allow" => [">"], "deny" => []}

    # Until the list has been read once, the current grant of an
    # infrastructure certificate is unknown, so it is refused rather than given
    # the stored grant. A host-enrolled component is unaffected.
    unloaded =
      authorize_request("EDGE",
        certificate: builtin,
        component_type: "core",
        static_users: static_users,
        static_users_loaded: false
      )

    assert unloaded.claims["nats"]["error"] == "static identity grants unavailable"
    refute Map.has_key?(unloaded.claims["nats"], "jwt")

    agent =
      authorize_request("EDGE",
        certificate: builtin,
        component_type: "agent",
        static_users: static_users,
        static_users_loaded: false
      )

    assert verify_response(agent.claims["nats"]["jwt"], agent.issuer_nkey)["nats"]["pub"] ==
             %{"allow" => ["metrics.example.>"], "deny" => []}

    # The stored grant stays for a host-enrolled component with the same
    # subject, and for an infrastructure certificate whose subject differs in
    # one attribute or carries an extra one.
    renamed =
      List.keyreplace(@builtin_subject, {2, 5, 4, 3}, 0, {{2, 5, 4, 3}, {:utf8String, "x"}})

    extra = @builtin_subject ++ [{{0, 9, 2342, 19_200_300, 100, 1, 25}, ~c"example"}]

    for {certificate, type} <- [
          {builtin, "agent"},
          {builtin, "nats-leaf"},
          {subject_certificate(renamed), "core"},
          {subject_certificate(extra), "core"}
        ] do
      stored =
        authorize_request("EDGE",
          certificate: certificate,
          component_type: type,
          static_users: static_users
        )

      user = verify_response(stored.claims["nats"]["jwt"], stored.issuer_nkey)
      assert user["nats"]["pub"] == %{"allow" => ["metrics.example.>"], "deny" => []}
    end
  end

  test "uses the shipped hub account and rejects the local leaf account name" do
    assert Configuration.deployment_account() == "SERVICERADAR"
    assert {:error, :nats_account_mismatch} = Configuration.bootstrap("EDGE", actor())
  end

  # Two of three sessions of one certificate hold a grant other than the one it
  # gets now: the stored grant an earlier static list left in place, and the
  # bare-fingerprint grant of an earlier release. Those two are disconnected and
  # the session the callout just granted is not.
  test "the hub scan disconnects a session whose grant is not the current grant" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    builtin = subject_certificate(@builtin_subject)

    {:ok, static_users} =
      StaticIdentityGrants.parse("""
      - user: "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US"
        publish:
          allow: ["metrics.sweep.>", "telemetry.example.bulk.>"]
        subscribe:
          allow: ["_INBOX.>"]
      """)

    {:ok, earlier_static_users} =
      StaticIdentityGrants.parse("""
      - user: "CN=example-tools,OU=Kubernetes,O=ExampleOrg"
        publish: {allow: [">"]}
        subscribe: {allow: [">"]}
      """)

    request = [certificate: builtin, component_type: "core"]
    current = authorize_request("EDGE", [static_users: static_users] ++ request)
    earlier = authorize_request("EDGE", [static_users: earlier_static_users] ++ request)
    current_name = granted_name(current)
    earlier_name = granted_name(earlier)
    refute current_name == earlier_name

    sessions = [
      {1, current_name},
      {2, earlier_name},
      {3, builtin.fingerprint}
      | Enum.map(4..70, &{&1, earlier_name})
    ]

    broker = start_broker!(builtin, sessions)
    observation = %{connz: %{offsets: %{}, turn: 0}, grant_kicks: %{}}
    observed = Authorizer.observe_account("EDGE", current.snapshot, static_users, observation)

    # A scan disconnects at most 64 such sessions; the rest wait for the next.
    assert FakeBroker.kicked(broker) == Enum.to_list(2..65)

    # A reconnect answered with the same stale grant waits for the retry
    # window instead of being disconnected again at once.
    restart_broker!(builtin, [{1, current_name}, {80, earlier_name}])
    Authorizer.observe_account("EDGE", current.snapshot, static_users, observed)
    assert FakeBroker.kicked(Process.whereis(:serviceradar_certificate_system)) == []

    aged = Map.new(observed.grant_kicks, fn {key, at} -> {key, at - 300_000} end)
    retry = %{observed | grant_kicks: aged}
    Authorizer.observe_account("EDGE", current.snapshot, static_users, retry)
    assert FakeBroker.kicked(Process.whereis(:serviceradar_certificate_system)) == [80]

    # Before the static list has been read the current grant is unknown.
    restart_broker!(builtin, sessions)
    Authorizer.observe_account("EDGE", current.snapshot, :unloaded, observation)
    assert FakeBroker.kicked(Process.whereis(:serviceradar_certificate_system)) == []
  end

  # A database outage during a tick (CNPG restarting) must not restart the
  # authorizer: a restart discards its policy snapshot, its static list and
  # its sessions. The unit tier has no database, so every policy read fails.
  test "a tick that cannot read policy keeps the authorizer's state" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    previous_file = Application.get_env(:serviceradar, :nats_static_users_file)
    dir = Path.join(System.tmp_dir!(), "static-users-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "static-users.yaml")

    File.write!(path, """
    - user: "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US"
      publish: {allow: ["metrics.sweep.>"]}
      subscribe: {allow: ["_INBOX.>"]}
    """)

    Application.put_env(:serviceradar, :nats_static_users_file, path)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous_file == nil do
        Application.delete_env(:serviceradar, :nats_static_users_file)
      else
        Application.put_env(:serviceradar, :nats_static_users_file, previous_file)
      end
    end)

    snapshot = allowing_snapshot(String.duplicate("ab", 32), [])
    sessions = %{{"hub-a", 7} => %{fingerprint: String.duplicate("ab", 32), expires_at: 1}}

    state = %{
      config: %{auth_mode: "static_mtls", account_name: "EDGE", issuer_nkey: "issuer"},
      signer: nil,
      snapshot: snapshot,
      subscription: nil,
      sessions: sessions,
      probe: nil,
      connz: %{offsets: %{}, turn: 0},
      grant_kicks: %{},
      static_users: %{},
      static_users_loaded: false,
      static_users_status: :ok,
      reason: nil
    }

    assert {:noreply, ticked} = Authorizer.handle_info(:tick, state)
    assert ticked.snapshot == snapshot
    assert ticked.sessions == sessions
    assert ticked.static_users_loaded
    assert map_size(ticked.static_users) == 1
    assert ticked.reason == "policy_unavailable"

    assert {:noreply, changed} = Authorizer.handle_info(:certificate_policy_changed, ticked)
    assert changed.snapshot == snapshot

    assert {:noreply, unconfigured} = Authorizer.handle_info(:tick, %{state | config: nil})
    assert unconfigured.config == nil
    assert unconfigured.reason == "policy_unavailable"
  end

  defp granted_name(granted) do
    verify_response(granted.claims["nats"]["jwt"], granted.issuer_nkey)["name"]
  end

  defp start_broker!(certificate, sessions) do
    connections =
      Enum.map(sessions, fn {cid, name} ->
        %{
          "kind" => "Client",
          "cid" => cid,
          "authorized_user" => name,
          "tls_peer_certs" => [
            %{
              "subject" => "CN=example-core,OU=Kubernetes,O=ExampleOrg,L=Example City,ST=EX,C=US",
              "cert_sha256" => certificate.fingerprint
            }
          ]
        }
      end)

    {:ok, pid} = FakeBroker.start_link(connections)
    on_exit(fn -> stop_broker() end)
    pid
  end

  defp restart_broker!(certificate, sessions) do
    stop_broker()
    start_broker!(certificate, sessions)
  end

  defp stop_broker do
    case Process.whereis(:serviceradar_certificate_system) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
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

  defp authorize_request(stored_account, opts \\ []) do
    issuer = Token.new_key(:account)
    {:ok, signer} = NKEYS.Keypair.from_seed(issuer.seed)
    user = Token.new_key(:user)
    server = server_keypair()
    leaf = Keyword.get_lazy(opts, :certificate, &leaf_certificate/0)
    request = authorization_request(server, issuer.public_key, user.public_key, leaf.pem)
    connection = publish_capture()
    snapshot = allowing_snapshot(leaf.fingerprint, opts)

    state = %{
      config: %{
        auth_mode: "static_mtls",
        account_name: stored_account,
        issuer_nkey: issuer.public_key
      },
      signer: signer,
      snapshot: snapshot,
      subscription: {connection, 1},
      sessions: %{},
      static_users: Keyword.get(opts, :static_users, %{}),
      static_users_loaded: Keyword.get(opts, :static_users_loaded, true)
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
      snapshot: snapshot,
      certificate_expires_at: DateTime.to_unix(hd(snapshot.certificates).not_after)
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

  # A synthetic certificate whose subject is exactly `attributes`.
  defp subject_certificate(attributes) do
    %{cert: root, key: key} = :public_key.pkix_test_root_cert(~c"synthetic root", [])
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(root, :otp)

    subject =
      {:rdnSequence,
       Enum.map(attributes, fn {oid, value} -> [{:AttributeTypeAndValue, oid, value}] end)}

    der =
      tbs
      |> put_elem(4, subject)
      |> put_elem(6, subject)
      |> :public_key.pkix_sign(key)

    %{
      fingerprint: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower),
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp allowing_snapshot(fingerprint, opts) do
    now = DateTime.utc_now()
    generated = DateTime.shift(now, second: -1)
    valid_until = DateTime.shift(now, second: Keyword.get(opts, :policy_seconds, 20))
    component_id = "edge-component-01"

    %{
      version: 1,
      generated_at: generated,
      valid_until: valid_until,
      components: [
        %{
          component_id: component_id,
          component_type: Keyword.get(opts, :component_type, "agent"),
          blocked: Keyword.get(opts, :blocked, false),
          generation: 1
        }
      ],
      certificates: [
        %{
          fingerprint: fingerprint,
          component_id: component_id,
          generation: 1,
          not_before: DateTime.shift(now, minute: -1),
          not_after: DateTime.shift(now, hour: Keyword.get(opts, :certificate_hours, 1))
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
