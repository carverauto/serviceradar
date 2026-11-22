defmodule ServiceRadar.Camera.ArchiveCredentialResolverTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.ArchiveStorageConfig
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  @binding_id "01900000-0000-7000-8000-000000000101"
  @secret_id "01900000-0000-7000-8000-000000000202"

  test "locks writer and reader broker grants to the binding HTTPS host, port, and bucket prefix" do
    binding = binding_fixture()
    secret_ref = SecretRefs.network_credential_ref(@secret_id)
    now = ~U[2026-11-15 08:00:00Z]

    assert {:ok, writer} =
             ArchiveCredentialResolver.grant_attrs(binding, :writer, @secret_id, now: now)

    assert writer.secret_id == @secret_id
    assert writer.secret_ref == secret_ref
    assert writer.purpose == "camera_archive_write"
    assert writer.allowed_schemes == ["https"]
    assert writer.allowed_hosts == ["objects.example.com"]
    assert writer.allowed_ports == [443]
    assert writer.allowed_paths == ["/example-recordings/recordings/v1/*"]
    assert writer.allowed_methods == ["PUT", "HEAD", "GET"]

    assert {:ok, reader} =
             ArchiveCredentialResolver.grant_attrs(binding, :reader, secret_ref, now: now)

    assert reader.purpose == "camera_archive_read"
    assert reader.allowed_methods == ["HEAD", "GET"]
    assert reader.metadata["destination_sha256"] == binding.destination_sha256

    assert {:ok, retention} =
             ArchiveCredentialResolver.grant_attrs(binding, :retention, secret_ref, now: now)

    assert retention.purpose == "camera_archive_retention"
    assert retention.allowed_schemes == ["https"]
    assert retention.allowed_hosts == ["objects.example.com"]
    assert retention.allowed_ports == [443]
    assert retention.allowed_paths == ["/example-recordings/recordings/v1/*"]
    assert retention.allowed_methods == ["DELETE", "HEAD"]
    assert retention.consumer_id == "camera-archive:retention:#{@binding_id}"
    assert retention.metadata["role"] == "retention"
    assert retention.metadata["destination_sha256"] == binding.destination_sha256

    tampered = Map.put(binding, :destination_sha256, String.duplicate("0", 64))

    assert {:error, :archive_binding_destination_mismatch} =
             ArchiveCredentialResolver.grant_attrs(tampered, :writer, @secret_id)

    assert {:error, :invalid_archive_credential_role} =
             ArchiveCredentialResolver.grant_attrs(binding, :admin, @secret_id)

    assert {:error, :invalid_credential_secret_id} =
             ArchiveCredentialResolver.grant_attrs(binding, :writer, "env:AWS_SECRET_ACCESS_KEY")

    v2_input =
      "operator:primary"
      |> Fixtures.archive_destination()
      |> Map.merge(%{
        "schema_version" => 2,
        "bucket" => "example-archive",
        "namespace" => "nvr/site-a"
      })

    {:ok, v2_attrs} = ArchiveDestination.attributes(v2_input)
    v2_binding = Map.put(v2_attrs, :id, @binding_id)

    assert {:ok, v2_grant} =
             ArchiveCredentialResolver.grant_attrs(v2_binding, :writer, @secret_id, now: now)

    assert v2_grant.allowed_paths == ["/example-archive/nvr/site-a/*"]
    assert v2_grant.metadata["destination_sha256"] == v2_attrs.destination_sha256
  end

  test "resolves native s3_compatible credentials into bounded runtime documents and rejects invalid secrets or grants" do
    binding = binding_fixture()

    {:ok, built} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICWRITER01",
          "secret_access_key" => "invented-writer-secret-material"
        },
        %{name: "Synthetic writer"}
      )

    secret =
      Map.merge(built, %{
        id: @secret_id,
        enabled: true,
        deleted_at: nil,
        metadata: Map.put(built.metadata, "generation", 3)
      })

    loader = fn @secret_id, _opts -> {:ok, secret} end
    issuer = fn attrs, _opts -> {:ok, Map.put(attrs, :id, "grant-1")} end

    broker = fn _grant, _opts ->
      {:ok, %{secret: secret, value: secret.secret_payload}}
    end

    assert {:ok, runtime_doc} =
             ArchiveCredentialResolver.resolve_for_binding(binding, :writer, @secret_id,
               secret_loader: loader,
               grant_issuer: issuer,
               broker: broker
             )

    assert runtime_doc == %{
             "reference" => SecretRefs.network_credential_ref(@secret_id),
             "generation" => 3,
             "access_key_id" => "SYNTHETICWRITER01",
             "secret_access_key" => "invented-writer-secret-material"
           }

    assert {:ok, retention_doc} =
             ArchiveCredentialResolver.resolve_for_binding(binding, :retention, @secret_id,
               secret_loader: loader,
               grant_issuer: issuer,
               broker: broker
             )

    assert retention_doc == runtime_doc

    {:ok, retention_grant} =
      ArchiveCredentialResolver.grant_attrs(binding, :retention, @secret_id)

    assert {:error, :grant_egress_scope_mismatch} =
             ArchiveCredentialResolver.resolve_runtime_credential(
               binding,
               :retention,
               Map.put(retention_grant, :allowed_methods, ["PUT", "DELETE", "HEAD"]),
               broker: broker
             )

    for {bad_secret, expected} <- [
          {Map.put(secret, :enabled, false), :credential_secret_inactive},
          {Map.put(secret, :provider, "snmp"), :credential_provider_mismatch},
          {Map.put(secret, :credential_kind, :api_token), :credential_kind_mismatch}
        ] do
      assert {:error, ^expected} =
               ArchiveCredentialResolver.issue_or_reuse_grant(binding, :writer, @secret_id,
                 secret_loader: fn _, _ -> {:ok, bad_secret} end,
                 grant_issuer: issuer
               )
    end

    {:ok, valid_grant} = ArchiveCredentialResolver.grant_attrs(binding, :writer, @secret_id)
    widened_grant = Map.put(valid_grant, :allowed_hosts, ["evil.example.com"])

    assert {:error, :grant_egress_scope_mismatch} =
             ArchiveCredentialResolver.resolve_runtime_credential(binding, :writer, widened_grant,
               broker: broker
             )

    sts_payload =
      Jason.encode!(%{
        "access_key_id" => "SYNTHETICWRITER01",
        "secret_access_key" => "invented-writer-secret-material",
        "session_token" => "unsupported-sts-token"
      })

    assert {:error, :invalid_s3_credential_payload} =
             ArchiveCredentialResolver.resolve_runtime_credential(binding, :writer, valid_grant,
               broker: fn _grant, _opts -> {:ok, %{secret: secret, value: sts_payload}} end
             )
  end

  @tag :tmp_dir
  test "ArchiveStorageConfig keeps HTTP default, accepts opt-in longshore, and fails closed on proxy or unknown transport",
       %{tmp_dir: tmp_dir} do
    fixture = write_storage_config_fixture(tmp_dir)

    assert {:ok, default_writer} = ArchiveStorageConfig.load(fixture.writer_path)
    assert default_writer.provider.transport == :http

    assert {:ok, default_reader} = ArchiveStorageConfig.load_read_storage(fixture.reader_path)
    assert default_reader.provider.transport == :http

    longshore_writer =
      write_json(
        tmp_dir,
        "writer-longshore.json",
        Map.put(fixture.writer_doc, "provider_transport", "longshore")
      )

    longshore_reader =
      write_json(
        tmp_dir,
        "reader-longshore.json",
        Map.put(fixture.reader_doc, "provider_transport", "longshore")
      )

    with_egress_proxy(nil, fn ->
      assert {:ok, loaded_writer} = ArchiveStorageConfig.load(longshore_writer)
      assert loaded_writer.provider.transport == :longshore
      assert loaded_writer.provider.proxy == nil

      assert {:ok, loaded_reader} = ArchiveStorageConfig.load_read_storage(longshore_reader)
      assert loaded_reader.provider.transport == :longshore
      assert loaded_reader.provider.proxy == nil
    end)

    with_egress_proxy("http://proxy.example.test:3128", fn ->
      assert {:error, :invalid_storage_configuration} =
               ArchiveStorageConfig.load(longshore_writer)

      assert {:error, :invalid_archive_read_storage_configuration} =
               ArchiveStorageConfig.load_read_storage(longshore_reader)
    end)

    bad_transport =
      write_json(
        tmp_dir,
        "writer-bad.json",
        Map.put(fixture.writer_doc, "provider_transport", "s3")
      )

    extra_key =
      write_json(tmp_dir, "writer-extra.json", Map.put(fixture.writer_doc, "unexpected", true))

    assert {:error, :invalid_storage_configuration} = ArchiveStorageConfig.load(bad_transport)
    assert {:error, :invalid_storage_configuration} = ArchiveStorageConfig.load(extra_key)
  end

  @tag :tmp_dir
  test "ArchiveStorageConfig supports per-request read storage and timeline reader client configs",
       %{tmp_dir: tmp_dir} do
    fixture = write_storage_config_fixture(tmp_dir)

    per_req_doc = %{
      "schema_version" => 1,
      "mode" => "per_request",
      "listener" => fixture.reader_doc["listener"]
    }

    per_req_path = write_json(tmp_dir, "per-request-reader.json", per_req_doc)
    assert {:ok, loaded} = ArchiveStorageConfig.load_read_storage(per_req_path)
    assert loaded.mode == :per_request
    assert loaded.max_concurrency == 8
    assert loaded.provider.transport == :http
    assert loaded.provider.portable == false
    assert {:ok, ^loaded} = ArchiveStorageConfig.load_timeline_read_storage(per_req_path)

    # Fixed mode config is refused by load_timeline_read_storage/1
    assert {:error, :invalid_archive_read_storage_configuration} =
             ArchiveStorageConfig.load_timeline_read_storage(fixture.reader_path)

    longshore_portable_path =
      write_json(
        tmp_dir,
        "per-request-longshore.json",
        Map.merge(per_req_doc, %{
          "max_concurrency" => 12,
          "provider_transport" => "longshore",
          "portable" => true
        })
      )

    with_egress_proxy(nil, fn ->
      assert {:ok, ls_cfg} =
               ArchiveStorageConfig.load_timeline_read_storage(longshore_portable_path)

      assert ls_cfg.max_concurrency == 12
      assert ls_cfg.provider.transport == :longshore
      assert ls_cfg.provider.portable == true
    end)

    client_doc = %{
      "schema_version" => 1,
      "storage" => fixture.writer_doc["runtime"]
    }

    client_path = write_json(tmp_dir, "timeline-client.json", client_doc)
    assert {:ok, %{client: client}} = ArchiveStorageConfig.load_timeline_reader(client_path)
    assert client.base_url == fixture.writer_doc["runtime"]["base_url"]

    assert {:error, :invalid_timeline_archive_reader_configuration} =
             ArchiveStorageConfig.load_timeline_reader(
               write_json(
                 tmp_dir,
                 "bad-timeline-client.json",
                 Map.put(client_doc, "binding_id", @binding_id)
               )
             )
  end

  defp binding_fixture do
    destination = Fixtures.archive_destination("allocation-example")
    {:ok, parsed} = ArchiveDestination.attributes(destination)
    Map.put(parsed, :id, @binding_id)
  end

  defp with_egress_proxy(value, fun) do
    previous = System.get_env("SERVICERADAR_EGRESS_PROXY")

    try do
      if is_nil(value) do
        System.delete_env("SERVICERADAR_EGRESS_PROXY")
      else
        System.put_env("SERVICERADAR_EGRESS_PROXY", value)
      end

      fun.()
    after
      if is_nil(previous) do
        System.delete_env("SERVICERADAR_EGRESS_PROXY")
      else
        System.put_env("SERVICERADAR_EGRESS_PROXY", previous)
      end
    end
  end

  defp write_storage_config_fixture(tmp_dir) do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    roots = Enum.uniq(certs.server_config[:cacerts] ++ certs.client_config[:cacerts])

    certfile =
      write_raw(
        tmp_dir,
        "server.crt",
        :public_key.pem_encode([{:Certificate, certs.server_config[:cert], :not_encrypted}])
      )

    {key_type, key_der} = certs.server_config[:key]

    keyfile =
      write_raw(
        tmp_dir,
        "server.key",
        :public_key.pem_encode([{key_type, key_der, :not_encrypted}])
      )

    cacertfile =
      write_raw(
        tmp_dir,
        "ca.crt",
        :public_key.pem_encode(Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
      )

    recorder_token_path = write_raw(tmp_dir, "recorder.token", String.duplicate("r", 40))
    runtime_token_path = write_raw(tmp_dir, "runtime.token", String.duplicate("s", 40))
    pin = :sha256 |> :crypto.hash(certs.client_config[:cert]) |> Base.encode16(case: :lower)
    tls = %{"certfile" => certfile, "keyfile" => keyfile, "cacertfile" => cacertfile}

    credential_ref = SecretRefs.network_credential_ref(@secret_id)

    credential_path =
      write_json(tmp_dir, "credentials.json", %{
        "reference" => credential_ref,
        "generation" => 1,
        "access_key_id" => "SYNTHETICWRITER01",
        "secret_access_key" => "invented-writer-secret-material"
      })

    destination = Fixtures.archive_destination("allocation-example")
    installation = %{deployment_ref: "01900000-0000-7000-8000-000000000303", generation: 1}
    desired_doc = desired_init_document(destination, credential_ref)
    {:ok, _} = ArchiveAuthorityConfig.parse(:init, installation, desired_doc)

    writer_doc = %{
      "schema_version" => 1,
      "deployment_ref" => installation.deployment_ref,
      "generation" => "1",
      "desired" => desired_doc,
      "provider_credentials_file" => credential_path,
      "listener" =>
        Map.merge(tls, %{
          "port" => 44_101,
          "token_file" => recorder_token_path,
          "recorder_certificate_sha256" => pin
        }),
      "runtime" =>
        Map.merge(tls, %{
          "base_url" => "https://core.example.com",
          "token_file" => runtime_token_path
        })
    }

    reader_doc = %{
      "schema_version" => 1,
      "binding_id" => @binding_id,
      "destination" => destination,
      "provider_credentials_file" => credential_path,
      "listener" =>
        Map.merge(tls, %{
          "port" => 44_102,
          "token_file" => recorder_token_path,
          "reader_certificate_sha256" => pin
        })
    }

    %{
      writer_doc: writer_doc,
      reader_doc: reader_doc,
      writer_path: write_json(tmp_dir, "writer.json", writer_doc),
      reader_path: write_json(tmp_dir, "reader.json", reader_doc)
    }
  end

  defp desired_init_document(destination, credential_ref) do
    checks =
      ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery)

    %{
      "schema_version" => 1,
      "revision" => "1",
      "binding_id" => @binding_id,
      "local_storage_id" => "01900000-0000-7000-8000-000000000404",
      "operation" => "init_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{
        "max_init_bytes" => 1_048_576,
        "max_operation_ms" => 5_000,
        "max_in_flight" => 1
      },
      "qualification_report" => %{
        "schema_version" => 1,
        "binding_id" => @binding_id,
        "destination" => destination,
        "provider_resource_id" => "synthetic-resource",
        "endpoint_type" => "synthetic-s3",
        "credential" => %{
          "reference" => credential_ref,
          "generation" => 1,
          "storage_service_id" => "synthetic-storage-service"
        },
        "policy_revision" => "synthetic-policy",
        "operation_mode" => "mediated_immutable_archive_v1",
        "issued_at_ms" => 1_800_000_000_000,
        "expires_at_ms" => 1_800_000_030_000,
        "result_ref" => "synthetic-evidence",
        "checks" => Map.new(checks, &{&1, "passed"})
      }
    }
  end

  defp write_json(dir, name, map), do: write_raw(dir, name, Jason.encode!(map))

  defp write_raw(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end
end
