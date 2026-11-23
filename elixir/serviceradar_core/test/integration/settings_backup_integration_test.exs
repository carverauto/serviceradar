defmodule ServiceRadar.Jobs.SettingsBackupIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Jobs.SettingsBackupDestination

  require Ash.Query

  @moduletag :integration

  @synthetic_access_key "AKIA_SYNTHETIC_INTEGRATION"
  @synthetic_secret_key "synthetic-integration-secret-key"
  @synthetic_cred_secret "synthetic-cred-secret-never-exported"

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    certs = generate_certs()
    test_pid = self()
    origin = start_tls_origin(certs.server_config, test_pid)
    previous_http_opts = Application.get_env(:serviceradar_core, :settings_backup_http_opts)

    Application.put_env(:serviceradar_core, :settings_backup_http_opts,
      proxy: nil,
      cacerts: Keyword.fetch!(certs.client_config, :cacerts)
    )

    on_exit(fn ->
      origin.stop.()

      if previous_http_opts do
        Application.put_env(:serviceradar_core, :settings_backup_http_opts, previous_http_opts)
      else
        Application.delete_env(:serviceradar_core, :settings_backup_http_opts)
      end
    end)

    %{origin: origin, actor: SystemActor.system(:settings_backup_integration_test)}
  end

  test "encrypts credentials at rest, preserves on partial update, and runs AshOban :due -> :run",
       ctx do
    attrs = %{
      enabled: true,
      provider: "linode_object_storage",
      endpoint: "https://localhost:#{ctx.origin.port}",
      bucket: "synthetic-tenant-backup",
      region: "us-east-1",
      prefix: "/tenant-a/",
      schedule_cron: "0 */6 * * *",
      access_key_id: @synthetic_access_key,
      secret_access_key: @synthetic_secret_key
    }

    assert {:ok, :created, dest} =
             SettingsBackupDestination.upsert_destination(attrs, actor: ctx.actor)

    assert dest.credentials_configured == true
    assert is_binary(dest.encrypted_access_key_id)
    assert is_binary(dest.encrypted_secret_access_key)
    refute dest.encrypted_access_key_id == @synthetic_access_key
    refute dest.encrypted_secret_access_key == @synthetic_secret_key

    # Partial update omitting credentials keeps existing ciphertext intact.
    assert {:ok, :updated, updated} =
             SettingsBackupDestination.upsert_destination(
               %{
                 enabled: true,
                 endpoint: attrs.endpoint,
                 bucket: attrs.bucket,
                 region: attrs.region,
                 prefix: "tenant-a",
                 schedule_cron: "*/15 * * * *"
               },
               actor: ctx.actor
             )

    assert updated.credentials_configured == true
    loaded = Ash.load!(updated, [:access_key_id, :secret_access_key], actor: ctx.actor)
    assert loaded.access_key_id == @synthetic_access_key
    assert loaded.secret_access_key == @synthetic_secret_key

    # Create a synthetic NetworkCredentialSecret to verify secret-free collection.
    {:ok, _cred} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Synthetic Backup Cred",
          provider: "awx",
          credential_kind: :api_token,
          public_fingerprint: "sha256:synthetic",
          secret_payload: @synthetic_cred_secret,
          metadata: %{"auth_method" => "bearer_token", "secret" => "drop-me"}
        },
        actor: ctx.actor
      )
      |> Ash.create()

    # Force next_run_at into the past so :due returns the singleton under nil actor.
    past = DateTime.shift(DateTime.utc_now(), minute: -2)

    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.settings_backup_destinations SET next_run_at = $1 WHERE id = $2",
      [past, Ecto.UUID.dump!(updated.id)]
    )

    due_result =
      SettingsBackupDestination
      |> Ash.Query.for_read(:due, %{}, actor: nil)
      |> Ash.read!()

    due_records =
      case due_result do
        %Ash.Page.Keyset{results: results} -> results
        results -> results
      end

    assert [due_dest] = due_records

    assert due_dest.id == updated.id

    assert {:ok, ran} =
             due_dest
             |> Ash.Changeset.for_update(:run, %{manual: false, reason: "scheduled"}, actor: nil)
             |> Ash.update()

    assert ran.last_export_status == "succeeded"
    assert is_nil(ran.last_export_error)
    assert %DateTime{} = ran.last_exported_at
    assert String.starts_with?(ran.last_export_object_key, "tenant-a/settings-export/")
    assert ran.last_export_etag == "\"etag-integration-1\""
    assert byte_size(ran.last_export_sha256) == 64
    assert DateTime.after?(ran.next_run_at, ran.last_exported_at)

    assert_receive {:origin_put, req1}
    assert_receive {:origin_put, req2}
    assert req2.path == "/synthetic-tenant-backup/tenant-a/settings-export/latest.json"
    refute String.contains?(req1.body, @synthetic_access_key)
    refute String.contains?(req1.body, @synthetic_secret_key)
    refute String.contains?(req1.body, @synthetic_cred_secret)
    refute String.contains?(req1.body, "drop-me")

    decoded = Jason.decode!(req1.body)
    assert decoded["reason"] == "scheduled"

    assert Enum.any?(
             decoded["terraform_resources"]["serviceradar_network_credential_secret"],
             fn s ->
               s["name"] == "Synthetic Backup Cred" and s["auth_method"] == "bearer_token"
             end
           )
  end

  test "records failed status and preserves latest.json metadata when S3 returns error", ctx do
    attrs = %{
      enabled: true,
      provider: "linode_object_storage",
      endpoint: "https://localhost:#{ctx.origin.port}",
      bucket: "synthetic-tenant-backup",
      region: "us-east-1",
      prefix: "tenant-fail",
      schedule_cron: "0 */6 * * *",
      access_key_id: @synthetic_access_key,
      secret_access_key: @synthetic_secret_key
    }

    assert {:ok, :created, dest} =
             SettingsBackupDestination.upsert_destination(attrs, actor: ctx.actor)

    assert {:ok, succeeded} =
             dest
             |> Ash.Changeset.for_update(:run, %{manual: true, reason: "manual"}, actor: nil)
             |> Ash.update()

    assert succeeded.last_export_status == "succeeded"
    assert_receive {:origin_put, _req1}
    assert_receive {:origin_put, _req2}

    assert {:ok, :updated, updated} =
             SettingsBackupDestination.upsert_destination(
               Map.put(attrs, :bucket, "fail-bucket"),
               actor: ctx.actor
             )

    assert {:error, _err} =
             updated
             |> Ash.Changeset.for_update(:run, %{manual: true, reason: "manual"}, actor: nil)
             |> Ash.update()

    assert {:ok, failed} = SettingsBackupDestination.get_singleton(actor: ctx.actor)
    assert failed.last_export_status == "failed"
    assert failed.last_export_error == "s3_http_status_500"
    assert failed.last_exported_at == succeeded.last_exported_at
    assert failed.last_export_object_key == succeeded.last_export_object_key
    assert failed.last_export_etag == succeeded.last_export_etag
    assert failed.last_export_sha256 == succeeded.last_export_sha256
    assert DateTime.after?(failed.next_run_at, failed.last_exported_at)

    assert_receive {:origin_put, req_fail}
    assert String.starts_with?(req_fail.path, "/fail-bucket/tenant-fail/settings-export/")
    refute String.ends_with?(req_fail.path, "/latest.json")
    refute_receive {:origin_put, _unexpected}, 150
  end

  defp generate_certs do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp start_tls_origin(server_config, test_pid) do
    listen_opts =
      server_config ++
        [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1},
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]

    {:ok, listener} = :ssl.listen(0, listen_opts)
    {:ok, {_addr, port}} = :ssl.sockname(listener)
    pid = spawn_link(fn -> origin_accept(listener, test_pid) end)
    %{port: port, stop: fn -> stop_proc(pid, fn -> :ssl.close(listener) end) end}
  end

  defp origin_accept(listener, test_pid) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, tls_socket} -> origin_serve(tls_socket, test_pid)
          _ -> :ok
        end

        origin_accept(listener, test_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        origin_accept(listener, test_pid)
    end
  end

  defp origin_serve(socket, test_pid) do
    with {:ok, raw} <- read_full_http_request(socket, "") do
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      [request_line | _] = String.split(head, "\r\n")
      [_method, path | _] = String.split(request_line, " ")
      send(test_pid, {:origin_put, %{path: path, body: body}})

      response =
        if String.starts_with?(path, "/fail-bucket/") do
          "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 5\r\nconnection: close\r\n\r\nerror"
        else
          "HTTP/1.1 200 OK\r\netag: \"etag-integration-1\"\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        end

      :ssl.send(socket, response)
    end

    :ssl.close(socket)
  end

  defp read_full_http_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        expected_len = parse_content_length(head)

        if byte_size(body) >= expected_len do
          {:ok, head <> "\r\n\r\n" <> binary_part(body, 0, expected_len)}
        else
          read_more(socket, acc)
        end

      [_] ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_full_http_request(socket, acc <> to_string(chunk))
      err -> err
    end
  end

  defp parse_content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, val] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(val)) do
              {len, ""} -> len
              _ -> 0
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp stop_proc(pid, close) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    close.()
  end
end
