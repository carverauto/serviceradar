defmodule ServiceRadarWebNG.CameraTimelineReader.NVRLocalTest do
  # Reads go through the application's read-client configuration, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarWebNG.CameraTimelineReader
  alias ServiceRadarWebNG.CameraTimelineReader.NVRLocal

  @moduletag :db_free
  @moduletag :tmp_dir

  @storage_id "00000000-0000-4000-8000-000000000021"
  @block_key String.duplicate("ab", 32)
  @descriptor_sha256 String.duplicate("cd", 32)
  @read_token "synthetic-web-ng-playback-read-token-0123"

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:ssl)
    previous = Application.get_env(:serviceradar_web_ng, :nvr_read_client)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :nvr_read_client, previous) end)
    %{certs: write_certs(ctx.tmp_dir)}
  end

  test "reads the planned fragment from the NVR that stores the entry, with the read token and descriptor digest",
       ctx do
    fragment = "synthetic fragment bytes for one cataloged block"
    port = start_read_peer(ctx.certs, 200, fragment)
    configure(ctx, port)

    assert NVRLocal.fetch_local(plan(fragment), deadline()) == {:ok, fragment}

    assert_receive {:read_request, request_line, authorization}, 2_000

    assert request_line ==
             "GET /v1/blocks/#{@block_key}/fragments/3?descriptor_sha256=#{@descriptor_sha256} HTTP/1.1"

    assert authorization == "Bearer " <> @read_token
  end

  test "maps the read listener's answers to the reader results copy resolution acts on", ctx do
    fragment = "synthetic fragment bytes for one cataloged block"

    for {status, body, expected} <- [
          {200, "bytes that are not the planned fragment", {:error, :integrity_mismatch}},
          {409, ~s({"error":"descriptor_mismatch"}), {:error, :integrity_mismatch}},
          {404, ~s({"error":"fragment_not_found"}), {:error, :not_found}},
          {503, ~s({"error":"read_unavailable"}), {:error, :unavailable}}
        ] do
      port = start_read_peer(ctx.certs, status, body)
      configure(ctx, port)
      assert NVRLocal.fetch_local(plan(fragment), deadline()) == expected, "answer #{status}"
    end
  end

  test "refuses without connecting when no member stores the entry or no read client is installed", ctx do
    configure(ctx, 1)
    other = %{plan("x") | storage_id: "00000000-0000-4000-8000-000000000022"}
    assert NVRLocal.fetch_local(other, deadline()) == {:error, :unknown_nvr_storage}

    Application.put_env(:serviceradar_web_ng, :nvr_read_client, config_file: nil, token_file: nil)
    assert NVRLocal.fetch_local(plan("x"), deadline()) == {:error, :nvr_read_not_configured}
  end

  test "a local copy the NVR reports as not the cataloged block is marked missing, not served", ctx do
    port = start_read_peer(ctx.certs, 409, ~s({"error":"block_not_sealed"}))
    configure(ctx, port)
    test_pid = self()

    local_plan = Map.merge(plan("x"), %{copy: :local, entry_id: "33333333-3333-4333-8333-333333333302"})

    assert CameraTimelineReader.execute_plans([local_plan], :auto,
             mark_local_integrity_failure: fn entry_id ->
               send(test_pid, {:marked_missing, entry_id})
               {:ok, %{entry: %{}, archive_verified?: false}}
             end
           ) == {:error, :recording_integrity_failed}

    assert_received {:marked_missing, "33333333-3333-4333-8333-333333333302"}
  end

  test "logs a warning with storage_id and reason for unavailable local reads without leaking tokens", ctx do
    configure(ctx, 1)
    unknown_storage_id = "00000000-0000-4000-8000-000000000022"
    unknown_plan = %{plan("x") | storage_id: unknown_storage_id}

    unknown_log =
      capture_log([level: :warning], fn ->
        assert NVRLocal.fetch_local(unknown_plan, deadline()) == {:error, :unknown_nvr_storage}
      end)

    assert unknown_log =~ unknown_storage_id
    assert unknown_log =~ ":unknown_nvr_storage"
    refute unknown_log =~ @read_token

    unauthorized_port = start_read_peer(ctx.certs, 401, ~s({"error":"unauthorized"}))
    configure(ctx, unauthorized_port)

    unauthorized_log =
      capture_log([level: :warning], fn ->
        assert {:error, {:read_status, 401, _}} = NVRLocal.fetch_local(plan("x"), deadline())
      end)

    assert unauthorized_log =~ @storage_id
    assert unauthorized_log =~ ":read_status"
    assert unauthorized_log =~ "401"
    refute unauthorized_log =~ @read_token

    for {status, body, expected} <- [
          {200, "x", {:ok, "x"}},
          {404, ~s({"error":"fragment_not_found"}), {:error, :not_found}},
          {409, ~s({"error":"descriptor_mismatch"}), {:error, :integrity_mismatch}}
        ] do
      port = start_read_peer(ctx.certs, status, body)
      configure(ctx, port)

      silent_log =
        capture_log([level: :warning], fn ->
          assert NVRLocal.fetch_local(plan("x"), deadline()) == expected
        end)

      assert silent_log == ""
    end
  end

  defp plan(bytes) do
    %{
      storage_id: @storage_id,
      block_key: @block_key,
      descriptor_sha256: @descriptor_sha256,
      selector: {:fragment, 3},
      expected_length: byte_size(bytes),
      expected_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp configure(ctx, port) do
    config_file = Path.join(ctx.tmp_dir, "read-client.json")
    token_file = Path.join(ctx.tmp_dir, "read-token")
    File.write!(token_file, @read_token)

    File.write!(
      config_file,
      Jason.encode!(%{
        "version" => 1,
        "port" => port,
        "ca_file" => ctx.certs.client_ca,
        "cert_file" => ctx.certs.client_cert,
        "key_file" => ctx.certs.client_key,
        "members" => %{"serviceradar-nvr-0" => %{"host" => "localhost", "storage_id" => @storage_id}}
      })
    )

    Application.put_env(:serviceradar_web_ng, :nvr_read_client, config_file: config_file, token_file: token_file)
  end

  # Synthetic server and client chains, as an installation's read listener uses.
  defp write_certs(dir) do
    algorithm = [digest: :sha256, key: {:namedCurve, :secp256r1}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    paths =
      for {name, tls} <- [server: data.server_config, client: data.client_config], into: %{} do
        {type, key} = tls[:key]
        cert = Path.join(dir, "#{name}.pem")
        key_path = Path.join(dir, "#{name}-key.pem")
        ca = Path.join(dir, "#{name}-ca.pem")
        File.write!(cert, :public_key.pem_encode([{:Certificate, tls[:cert], :not_encrypted}]))
        File.write!(key_path, :public_key.pem_encode([{type, key, :not_encrypted}]))
        File.write!(ca, :public_key.pem_encode(Enum.map(tls[:cacerts], &{:Certificate, &1, :not_encrypted})))
        {name, %{cert: cert, key: key_path, ca: ca}}
      end

    %{
      server_cert: paths.server.cert,
      server_key: paths.server.key,
      server_ca: paths.server.ca,
      client_cert: paths.client.cert,
      client_key: paths.client.key,
      client_ca: paths.client.ca
    }
  end

  # One-request TLS peer standing in for an NVR read listener.
  defp start_read_peer(certs, status, body) do
    {:ok, listen} =
      :ssl.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        cacertfile: String.to_charlist(certs.server_ca),
        certfile: String.to_charlist(certs.server_cert),
        keyfile: String.to_charlist(certs.server_key)
      ])

    {:ok, {_addr, port}} = :ssl.sockname(listen)
    test_pid = self()
    peer = spawn(fn -> serve_once(listen, test_pid, status, body) end)

    on_exit(fn ->
      Process.exit(peer, :kill)
      _ = :ssl.close(listen)
    end)

    port
  end

  defp serve_once(listen, test_pid, status, body) do
    with {:ok, transport} <- :ssl.transport_accept(listen, 5_000),
         {:ok, socket} <- :ssl.handshake(transport, 5_000),
         {:ok, head} <- read_head(socket, <<>>) do
      [request_line | headers] = String.split(head, "\r\n")

      authorization =
        Enum.find_value(headers, fn header ->
          case String.split(header, ": ", parts: 2) do
            [name, value] -> if String.downcase(name) == "authorization", do: value
            _ -> nil
          end
        end)

      send(test_pid, {:read_request, request_line, authorization})

      :ssl.send(socket, [
        "HTTP/1.1 #{status} Answer\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
        body
      ])

      _ = :ssl.recv(socket, 0, 2_000)
    end
  end

  defp read_head(socket, seen) do
    case :binary.split(seen, "\r\n\r\n") do
      [head, _rest] ->
        {:ok, head}

      [_partial] ->
        with {:ok, chunk} <- :ssl.recv(socket, 0, 5_000), do: read_head(socket, seen <> chunk)
    end
  end
end
