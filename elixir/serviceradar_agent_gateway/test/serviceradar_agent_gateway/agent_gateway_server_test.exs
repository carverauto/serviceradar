defmodule ServiceRadarAgentGateway.AgentGatewayServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.Config

  setup do
    previous_config =
      try do
        Config.get()
      rescue
        # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
        ArgumentError -> nil
      end

    on_exit(fn ->
      if previous_config do
        Config.setup(
          gateway_id: previous_config.gateway_id,
          domain: previous_config.domain,
          capabilities: previous_config.capabilities
        )
      end
    end)

    :ok
  end

  test "uses configured logical gateway id for external attribution" do
    Config.setup(gateway_id: "gateway-platform", domain: "demo")

    assert AgentGatewayServer.gateway_id() == "gateway-platform"
    refute AgentGatewayServer.gateway_id() == Atom.to_string(node())
  end

  describe "device_attrs_from_request/3 — gateway bridge for identity evidence" do
    # These tests guard the bridge that carries host_macs from the protobuf
    # request to AgentGatewaySync.ensure_device_for_agent/2. If host_macs is
    # accidentally removed from device_attrs_from_request the evidence silently
    # stops reaching core identity reconciliation, so each request type that
    # calls ensure_device_for_agent is covered here. host_interfaces, the
    # classified inventory core decides identity from, rides the same bridge.

    @physical_nic %Monitoring.HostInterface{
      name: "eno1",
      mac: "00:00:5e:00:53:01",
      permanent_mac: "00:00:5e:00:53:01",
      ips: ["192.0.2.10", "2001:db8::10"],
      oper_state: "up",
      kind: :HOST_INTERFACE_KIND_PHYSICAL,
      mac_provenance: :MAC_PROVENANCE_PERMANENT,
      master: ""
    }

    @physical_nic_attrs %{
      name: "eno1",
      mac: "00:00:5e:00:53:01",
      permanent_mac: "00:00:5e:00:53:01",
      ips: ["192.0.2.10", "2001:db8::10"],
      oper_state: "up",
      kind: :HOST_INTERFACE_KIND_PHYSICAL,
      mac_provenance: :MAC_PROVENANCE_PERMANENT,
      master: ""
    }

    test "unary enrollment hello (AgentHelloRequest) forwards host_macs to device attrs" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-01",
        hostname: "node-a",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.10",
        host_macs: ["00:00:5e:00:53:01"],
        host_interfaces: [@physical_nic]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.10")

      assert attrs.host_macs == ["00:00:5e:00:53:01"]
      assert attrs.host_interfaces == [@physical_nic_attrs]
      assert attrs.source_ip == "192.0.2.10"
      assert attrs.partition == "partition-1"
    end

    test "control-stream hello (ControlStreamHello) forwards host_macs to device attrs" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-02",
        hostname: "node-b",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.11",
        host_macs: ["00:00:5e:00:53:02", "00:00:5e:00:53:03"],
        host_interfaces: [@physical_nic]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.11")

      assert attrs.host_macs == ["00:00:5e:00:53:02", "00:00:5e:00:53:03"]
      assert attrs.host_interfaces == [@physical_nic_attrs]
      assert attrs.source_ip == "192.0.2.11"
      assert attrs.partition == "partition-2"
    end

    test "unary enrollment hello without host_macs is backward compatible" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-03",
        hostname: "node-c",
        host_ip: "192.0.2.12"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.12")

      assert attrs.host_macs == []
      assert attrs.host_interfaces == []
    end

    test "control-stream hello without host_macs is backward compatible" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-04",
        hostname: "node-d",
        host_ip: "192.0.2.13"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.13")

      assert attrs.host_macs == []
      assert attrs.host_interfaces == []
    end

    # A gateway or core built before host_interfaces decodes a hello with the schema it was built
    # with. The fields it reads keep their numbers and values, and the inventory is skipped as an
    # unknown field; an agent built before it sends a hello that decodes with no inventory.
    test "hello wire format stays readable across the host_interfaces change" do
      for {current, legacy} <- [
            {Monitoring.AgentHelloRequest, __MODULE__.LegacyAgentHello},
            {Monitoring.ControlStreamHello, __MODULE__.LegacyControlStreamHello}
          ] do
        new_hello =
          struct(current,
            agent_id: "agent-test-06",
            host_ip: "192.0.2.14",
            host_macs: ["00:00:5e:00:53:05"],
            host_interfaces: [@physical_nic]
          )

        read_by_older = new_hello |> current.encode() |> legacy.decode()
        assert read_by_older.host_ip == "192.0.2.14"
        assert read_by_older.host_macs == ["00:00:5e:00:53:05"]

        from_older =
          legacy
          |> struct(agent_id: "agent-test-06", host_ip: "192.0.2.14", host_macs: ["00:00:5e:00:53:05"])
          |> legacy.encode()
          |> current.decode()

        assert from_older.host_macs == ["00:00:5e:00:53:05"]
        assert from_older.host_interfaces == []
      end
    end

    test "prefers reported host_ip over TCP peer address for source_ip" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-05",
        host_ip: "192.0.2.20",
        host_macs: ["00:00:5e:00:53:04"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "198.51.100.5")

      assert attrs.source_ip == "192.0.2.20"
    end
  end

  describe "config_payload_summary/1" do
    test "computes config_json_bytes, mapper_jobs, and plugins without decoding config_json" do
      raw_payload = "<<non-json-payload-that-would-fail-decode>>"

      summary =
        AgentGatewayServer.config_payload_summary(%{
          config_json: raw_payload,
          mapper_jobs_count: 3,
          plugins: [%{assignment_id: "p-1"}, %{assignment_id: "p-2"}]
        })

      assert summary == %{
               config_json_bytes: byte_size(raw_payload),
               mapper_jobs: 3,
               plugins: 2
             }
    end

    test "defaults missing summary fields to zero" do
      assert AgentGatewayServer.config_payload_summary(%{}) == %{
               config_json_bytes: 0,
               mapper_jobs: 0,
               plugins: 0
             }
    end
  end

  describe "authenticated host identity forwarding" do
    setup do
      start_core_peer!()

      {:ok, _} = Application.ensure_all_started(:horde)
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if !Process.whereis(ServiceRadar.PubSub) do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      if !Process.whereis(ProcessRegistry.registry_name()) do
        Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
      end

      if !Process.whereis(AgentRegistryProxy), do: start_supervised!(AgentRegistryProxy)
      CertificateTestHelpers.ensure_revocation_store!()
      Config.setup(gateway_id: "gateway-host-identity", domain: "test", capabilities: [])

      parent_dir = CertificateTestHelpers.unique_tmp_dir!("gateway-host-identity")
      on_exit(fn -> File.rm_rf(parent_dir) end)
      ca_cert = Path.join(parent_dir, "root.pem")
      ca_key = Path.join(parent_dir, "root-key.pem")
      CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

      agent_id = "agent-host-identity"

      {:ok, bundle} =
        CertIssuer.issue_agent_bundle(agent_id, "default", :agent,
          ca_cert_file: ca_cert,
          ca_key_file: ca_key,
          temp_parent_dir: parent_dir,
          audit_writer: nil
        )

      stream =
        bundle.certificate_pem
        |> CertificateTestHelpers.certificate_der!()
        |> CertificateTestHelpers.cert_stream()

      %{agent_id: agent_id, stream: stream}
    end

    for transport <- [:unary, :control] do
      @transport transport
      test "#{transport} hello forwards announced host MACs and peer certificate metadata through core RPC",
           context do
        request = host_hello(@transport, context.agent_id)
        assert_enrolled(@transport, request, context.stream)

        assert_receive {:core_rpc, :upsert_agent, [agent_id, agent_attrs]}, 1_000
        assert agent_id == context.agent_id
        assert %DateTime{} = agent_attrs.cert_not_before
        assert %DateTime{} = agent_attrs.cert_expires_at
        assert DateTime.diff(agent_attrs.cert_expires_at, agent_attrs.cert_not_before, :second) == 90 * 86_400
        assert byte_size(agent_attrs.cert_serial) > 0
        assert byte_size(agent_attrs.cert_fingerprint_sha256) == 64

        assert_receive {:core_rpc, :ensure_device_for_agent, [^agent_id, attrs]}, 1_000
        assert attrs.source_ip == "192.0.2.37"
        assert attrs.host_macs == ["02:00:00:00:01:03"]
        assert attrs.partition == "default"
        refute_receive {:core_rpc, :ensure_device_for_agent, _}
      end

      @transport transport
      test "#{transport} hello rejects a certificate identity mismatch before core RPC",
           context do
        request = host_hello(@transport, "agent-other-identity")

        error =
          assert_raise GRPC.RPCError, ~r/component_id mismatch/, fn ->
            assert_enrolled(@transport, request, context.stream)
          end

        assert error.status == GRPC.Status.permission_denied()
        refute_receive {:core_rpc, _, _}
      end
    end
  end

  describe "renew_certificate/2 — mTLS certificate renewal and predecessor retirement" do
    setup do
      CertificateTestHelpers.ensure_revocation_store!()
      AgentCertificateRevocation.clear()
      {:ok, _} = Application.ensure_all_started(:horde)
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if !Process.whereis(ServiceRadar.PubSub) do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      if !Process.whereis(ProcessRegistry.registry_name()) do
        Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
      end

      if !Process.whereis(AgentRegistryProxy), do: start_supervised!(AgentRegistryProxy)
      Config.setup(gateway_id: "gateway-renewal-test", domain: "default")

      parent_dir = CertificateTestHelpers.unique_tmp_dir!("gateway-server-renewal")
      ca_cert = Path.join(parent_dir, "root.pem")
      ca_key = Path.join(parent_dir, "root-key.pem")
      CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

      previous_issuer_opts = Application.get_env(:serviceradar_agent_gateway, :cert_issuer_opts)

      Application.put_env(:serviceradar_agent_gateway, :cert_issuer_opts,
        ca_cert_file: ca_cert,
        ca_key_file: ca_key,
        temp_parent_dir: parent_dir,
        audit_writer: nil
      )

      on_exit(fn ->
        if previous_issuer_opts do
          Application.put_env(:serviceradar_agent_gateway, :cert_issuer_opts, previous_issuer_opts)
        else
          Application.delete_env(:serviceradar_agent_gateway, :cert_issuer_opts)
        end

        if Process.whereis(AgentCertificateRevocation), do: AgentCertificateRevocation.clear()
        File.rm_rf(parent_dir)
      end)

      agent_id = "agent-renew-01"

      {:ok, initial_bundle} =
        CertIssuer.issue_agent_bundle(agent_id, "default", :agent,
          ca_cert_file: ca_cert,
          ca_key_file: ca_key,
          temp_parent_dir: parent_dir,
          audit_writer: nil
        )

      old_cert_der = CertificateTestHelpers.certificate_der!(initial_bundle.certificate_pem)
      {:ok, old_identity} = ComponentIdentityResolver.resolve_from_cert(old_cert_der)

      %{
        agent_id: agent_id,
        parent_dir: parent_dir,
        ca_cert: ca_cert,
        ca_key: ca_key,
        old_bundle: initial_bundle,
        old_cert_der: old_cert_der,
        old_identity: old_identity,
        old_stream: CertificateTestHelpers.cert_stream(old_cert_der)
      }
    end

    for transport <- [:unary, :control] do
      @transport transport
      test "#{transport} Hello retires only the predecessor after renewal retries", context do
        start_core_peer!()

        csr_der_1 = build_test_csr_der!(context.agent_id, "default")

        resp_1 =
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: csr_der_1},
            context.old_stream
          )

        assert byte_size(resp_1.certificate_pem) > 0
        assert byte_size(resp_1.ca_chain_pem) > 0
        assert byte_size(resp_1.serial_number) > 0
        assert byte_size(resp_1.certificate_fingerprint) == 64
        assert resp_1.not_after_unix > resp_1.not_before_unix
        refute resp_1.certificate_fingerprint == context.old_identity.certificate_fingerprint

        # Predecessor MUST NOT be revoked before the agent completes Hello with the successor,
        # so a lost response or mid-write crash allows retry on the predecessor certificate.
        refute AgentCertificateRevocation.revoked?(context.old_identity)

        csr_der_2 = build_test_csr_der!(context.agent_id, "default")

        resp_2 =
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: csr_der_2},
            context.old_stream
          )

        assert byte_size(resp_2.certificate_pem) > 0
        refute AgentCertificateRevocation.revoked?(context.old_identity)

        successor_stream =
          resp_2.certificate_pem
          |> CertificateTestHelpers.certificate_der!()
          |> CertificateTestHelpers.cert_stream()

        assert_enrolled(@transport, host_hello(@transport, context.agent_id), successor_stream)

        unrelated_identity = %{
          context.old_identity
          | component_id: "agent-unrelated",
            certificate_fingerprint: String.duplicate("a", 64)
        }

        refute AgentCertificateRevocation.revoked?(unrelated_identity)
        assert AgentCertificateRevocation.revoked_reason(unrelated_identity) == nil

        assert AgentCertificateRevocation.revoked?(context.old_identity)
        assert AgentCertificateRevocation.revoked_reason(context.old_identity) == "superseded_by_renewal"

        # Presenting the retired predecessor certificate for another renewal is now denied.
        error =
          assert_raise GRPC.RPCError, ~r/certificate_revoked/, fn ->
            AgentGatewayServer.renew_certificate(
              %Monitoring.CertificateRenewalRequest{csr_der: csr_der_2},
              context.old_stream
            )
          end

        assert error.status == GRPC.Status.permission_denied()
      end
    end

    for failure <- [:expired, :revoked] do
      @failure failure
      test "rejects a peer that becomes #{@failure} at the signing boundary", context do
        counter = :counters.new(1, [])
        now = DateTime.utc_now()
        failure = @failure

        now_fn = fn ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            now
          else
            case failure do
              :expired ->
                context.old_identity.cert_not_after

              :revoked ->
                AgentCertificateRevocation.revoke_fingerprint(context.old_identity.certificate_fingerprint)
                now
            end
          end
        end

        opts = Application.fetch_env!(:serviceradar_agent_gateway, :cert_issuer_opts)
        Application.put_env(:serviceradar_agent_gateway, :cert_issuer_opts, Keyword.put(opts, :now, now_fn))

        error =
          assert_raise GRPC.RPCError, fn ->
            AgentGatewayServer.renew_certificate(
              %Monitoring.CertificateRenewalRequest{csr_der: build_test_csr_der!(context.agent_id, "default")},
              context.old_stream
            )
          end

        assert error.status == GRPC.Status.permission_denied()
        assert error.message == "certificate_#{@failure}"
      end
    end

    test "rejects expired and not-yet-valid peer certificates with PERMISSION_DENIED", context do
      csr_der = build_test_csr_der!(context.agent_id, "default")

      expired_now = DateTime.shift(context.old_identity.cert_not_after, minute: 1)

      Application.put_env(
        :serviceradar_agent_gateway,
        :cert_issuer_opts,
        Keyword.put(
          Application.get_env(:serviceradar_agent_gateway, :cert_issuer_opts, []),
          :now,
          expired_now
        )
      )

      expired_error =
        assert_raise GRPC.RPCError, ~r/certificate_expired/, fn ->
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: csr_der},
            context.old_stream
          )
        end

      assert expired_error.status == GRPC.Status.permission_denied()

      future_now = DateTime.shift(context.old_identity.cert_not_before, minute: -1)

      Application.put_env(
        :serviceradar_agent_gateway,
        :cert_issuer_opts,
        Keyword.put(
          Application.get_env(:serviceradar_agent_gateway, :cert_issuer_opts, []),
          :now,
          future_now
        )
      )

      not_yet_valid_error =
        assert_raise GRPC.RPCError, ~r/certificate_not_yet_valid/, fn ->
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: csr_der},
            context.old_stream
          )
        end

      assert not_yet_valid_error.status == GRPC.Status.permission_denied()
    end

    test "live mTLS renewal keeps the predecessor usable when successor Hello fails", context do
      {:ok, _} = Application.ensure_all_started(:grpc)
      {:ok, _} = Application.ensure_all_started(:cowboy)
      cert_path = Path.join(context.parent_dir, "peer.pem")
      key_path = Path.join(context.parent_dir, "peer-key.pem")
      File.write!(cert_path, context.old_bundle.certificate_pem)
      File.write!(key_path, context.old_bundle.private_key_pem)

      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      server_credential =
        GRPC.Credential.new(
          ssl: [
            certfile: cert_path,
            keyfile: key_path,
            cacertfile: context.ca_cert,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        )

      start_supervised!(
        {GRPC.Server.Supervisor,
         endpoint: ServiceRadarAgentGateway.Endpoint,
         port: port,
         start_server: true,
         adapter_opts: [ip: {127, 0, 0, 1}, cred: server_credential]}
      )

      connect = fn client_cert ->
        credential =
          GRPC.Credential.new(
            ssl: [
              certfile: client_cert,
              keyfile: key_path,
              cacertfile: context.ca_cert,
              verify: :verify_peer,
              server_name_indication: ~c"agent-renew-01.default.serviceradar"
            ]
          )

        {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", cred: credential)
        on_exit(fn -> GRPC.Stub.disconnect(channel) end)
        channel
      end

      old_channel = connect.(cert_path)
      stub = Monitoring.AgentGatewayService.Stub

      assert {:error, %GRPC.RPCError{status: 7}} =
               stub.renew_certificate(old_channel, %Monitoring.CertificateRenewalRequest{
                 csr_der: build_test_csr_der!("other-agent-99", "default")
               })

      {csr_der, 0} =
        System.cmd("openssl", [
          "req",
          "-new",
          "-key",
          key_path,
          "-outform",
          "DER",
          "-subj",
          "/CN=agent-renew-01.default.serviceradar",
          "-addext",
          "subjectAltName=URI:spiffe://serviceradar.local/agent/default/agent-renew-01,DNS:agent-renew-01.default.serviceradar"
        ])

      request = %Monitoring.CertificateRenewalRequest{csr_der: csr_der}

      {:CertificationRequest, info, algorithm, <<first, rest::binary>>} =
        :public_key.der_decode(:CertificationRequest, csr_der)

      tampered_csr =
        :public_key.der_encode(
          :CertificationRequest,
          {:CertificationRequest, info, algorithm, <<Bitwise.bxor(first, 0xFF), rest::binary>>}
        )

      assert {:error, %GRPC.RPCError{status: 3, message: "invalid_csr_signature"}} =
               stub.renew_certificate(old_channel, %Monitoring.CertificateRenewalRequest{csr_der: tampered_csr})

      {wrong_san_csr, 0} =
        System.cmd("openssl", [
          "req",
          "-new",
          "-key",
          key_path,
          "-outform",
          "DER",
          "-subj",
          "/CN=agent-renew-01.default.serviceradar",
          "-addext",
          "subjectAltName=DNS:other-agent.example.com"
        ])

      assert {:error, %GRPC.RPCError{status: 7, message: "csr_identity_mismatch"}} =
               stub.renew_certificate(old_channel, %Monitoring.CertificateRenewalRequest{csr_der: wrong_san_csr})

      {weak_csr, 0} =
        System.cmd("openssl", [
          "req",
          "-new",
          "-newkey",
          "rsa:1024",
          "-nodes",
          "-keyout",
          Path.join(context.parent_dir, "weak-key.pem"),
          "-outform",
          "DER",
          "-subj",
          "/CN=agent-renew-01.default.serviceradar"
        ])

      assert {:error, %GRPC.RPCError{status: 3, message: "weak_public_key"}} =
               stub.renew_certificate(old_channel, %Monitoring.CertificateRenewalRequest{csr_der: weak_csr})

      assert {:ok, successor} = stub.renew_certificate(old_channel, request)
      assert {:ok, _retry} = stub.renew_certificate(old_channel, request)

      successor_path = Path.join(context.parent_dir, "successor.pem")
      File.write!(successor_path, successor.certificate_pem)
      successor_channel = connect.(successor_path)

      assert {:error, %GRPC.RPCError{status: 14}} =
               stub.hello(successor_channel, host_hello(:unary, context.agent_id))

      # The protocol retires the predecessor only after Hello completes successfully.
      assert {:ok, _retry_after_failed_hello} = stub.renew_certificate(old_channel, request)

      :ok = AgentCertificateRevocation.revoke_fingerprint(context.old_identity.certificate_fingerprint)

      assert {:error, %GRPC.RPCError{status: 7, message: "certificate_revoked"}} =
               stub.renew_certificate(old_channel, request)

      IO.puts(
        "Live mTLS RPC results: wrong CN/SAN=PERMISSION_DENIED; tampered signature/weak key=INVALID_ARGUMENT; " <>
          "renewal and retry=OK; successor Hello=UNAVAILABLE; predecessor retry after failed Hello=OK; " <>
          "revoked predecessor=PERMISSION_DENIED"
      )
    end

    test "rejects forged CSR with mismatched identity or invalid signature", context do
      forged_identity_csr = build_test_csr_der!("other-agent-99", "default")

      mismatch_error =
        assert_raise GRPC.RPCError, ~r/csr_identity_mismatch/, fn ->
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: forged_identity_csr},
            context.old_stream
          )
        end

      assert mismatch_error.status == GRPC.Status.permission_denied()

      valid_csr = build_test_csr_der!(context.agent_id, "default")
      {:CertificationRequest, info, sig_algo, sig} = :public_key.der_decode(:CertificationRequest, valid_csr)
      <<first, rest::binary>> = sig
      bad_sig = <<Bitwise.bxor(first, 0xFF), rest::binary>>
      tampered_csr = :public_key.der_encode(:CertificationRequest, {:CertificationRequest, info, sig_algo, bad_sig})

      sig_error =
        assert_raise GRPC.RPCError, ~r/invalid_csr_signature/, fn ->
          AgentGatewayServer.renew_certificate(
            %Monitoring.CertificateRenewalRequest{csr_der: tampered_csr},
            context.old_stream
          )
        end

      assert sig_error.status == GRPC.Status.invalid_argument()
    end
  end

  defp start_core_peer! do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:gateway_host_identity_test, :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end

    basename = "host_identity_core_#{System.unique_integer([:positive])}"

    previous_basename =
      Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)

    Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)

    on_exit(fn ->
      if previous_basename do
        Application.put_env(
          :serviceradar_agent_gateway,
          :cluster_core_node_basename,
          previous_basename
        )
      else
        Application.delete_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
      end
    end)

    peer =
      start_supervised!(%{
        id: :host_identity_core_peer,
        start:
          {:peer, :start_link,
           [
             %{
               name: String.to_atom(basename),
               connection: :standard_io,
               args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
             }
           ]},
        restart: :temporary
      })

    core_node = :peer.call(peer, :erlang, :node, [])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

    :peer.call(peer, Code, :compile_string, [
      """
      defmodule ServiceRadar.Edge.AgentGatewaySync do
        def upsert_agent(agent_id, attrs) do
          notify(:upsert_agent, [agent_id, attrs])
          :ok
        end

        def ensure_device_for_agent(agent_id, attrs) do
          notify(:ensure_device_for_agent, [agent_id, attrs])
          {:ok, "synthetic-device"}
        end

        def reconcile_agent_release(agent_id) do
          notify(:reconcile_agent_release, [agent_id])
          :ok
        end

        defp notify(function, args) do
          send(:persistent_term.get(:host_identity_test_owner), {:core_rpc, function, args})
        end
      end
      """
    ])

    :ok = :peer.call(peer, :persistent_term, :put, [:host_identity_test_owner, self()])
    assert Node.connect(core_node)
  end

  defp build_test_csr_der!(component_id, partition_id) do
    cn = "#{component_id}.#{partition_id}.serviceradar"
    spiffe = "spiffe://serviceradar.local/agent/#{partition_id}/#{component_id}"

    args = [
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:prime256v1",
      "-nodes",
      "-keyout",
      "/dev/null",
      "-subj",
      "/CN=#{cn}",
      "-addext",
      "subjectAltName=URI:#{spiffe},DNS:#{cn}"
    ]

    case System.cmd("openssl", args, stderr_to_stdout: false) do
      {pem, 0} ->
        [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(pem)
        der

      {output, status} ->
        flunk("openssl CSR generation failed (#{status}): #{output}")
    end
  end

  defp host_hello(transport, agent_id) do
    fields = [
      agent_id: agent_id,
      host_ip: "192.0.2.37",
      host_macs: ["02:00:00:00:01:03"],
      hostname: "host01.example.com",
      os: "linux",
      arch: "amd64"
    ]

    case transport do
      :unary -> struct!(Monitoring.AgentHelloRequest, fields)
      :control -> struct!(Monitoring.ControlStreamHello, fields)
    end
  end

  defp assert_enrolled(:unary, request, stream) do
    assert %Monitoring.AgentHelloResponse{accepted: true} =
             AgentGatewayServer.hello(request, stream)
  end

  defp assert_enrolled(:control, request, stream) do
    assert :ok =
             AgentGatewayServer.control_stream(
               [%Monitoring.ControlStreamRequest{payload: {:hello, request}}],
               stream
             )
  end

  defmodule LegacyAgentHello do
    @moduledoc false
    # AgentHelloRequest's identity fields as they were before host_interfaces (field 13).
    use Protobuf, syntax: :proto3

    field(:agent_id, 1, type: :string)
    field(:host_ip, 11, type: :string)
    field(:host_macs, 12, repeated: true, type: :string)
  end

  defmodule LegacyControlStreamHello do
    @moduledoc false
    # ControlStreamHello's identity fields as they were before host_interfaces (field 15).
    use Protobuf, syntax: :proto3

    field(:agent_id, 1, type: :string)
    field(:host_ip, 11, type: :string)
    field(:host_macs, 13, repeated: true, type: :string)
  end
end
