defmodule ServiceRadar.Inventory.AdvisoryFeeds.AcquisitionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.AdvisoryFeeds.Acquisition

  setup do
    root = Path.join(System.tmp_dir!(), "advisory-acq-#{System.unique_integer([:positive])}")
    System.put_env("SERVICERADAR_ADVISORY_STAGING_DIR", root)

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADVISORY_STAGING_DIR")
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "extract/2 classification" do
    test "classifies a zip of *.json.gz shards as :json_gz_shards", %{root: root} do
      extracted = Path.join(root, "extract-shards")
      File.mkdir_p!(extracted)

      zip =
        build_zip(root, [{~c"nvdcve-2.0-001.json.gz", :zlib.gzip(~s({"vulnerabilities":[]}))}])

      assert {:ok, :json_gz_shards} = Acquisition.extract(zip, extracted)
      assert File.exists?(Path.join(extracted, "nvdcve-2.0-001.json.gz"))
    end

    test "classifies a zip of a single .json as :json", %{root: root} do
      extracted = Path.join(root, "extract-json")
      File.mkdir_p!(extracted)

      zip = build_zip(root, [{~c"vulncheck_known_exploited_vulnerabilities.json", "[]"}])

      assert {:ok, :json} = Acquisition.extract(zip, extracted)
    end
  end

  describe "resolve_backup_index/3 (two-step backup, Bearer)" do
    test "returns the first data[] entry and sends a Bearer header" do
      test_pid = self()

      http_get_json = fn url, headers ->
        send(test_pid, {:index_request, url, headers})
        {:ok, %{"data" => [%{"url" => "https://s3.example/presigned.zip", "sha256" => "abc"}]}}
      end

      assert {:ok, %{"url" => "https://s3.example/presigned.zip"}} =
               Acquisition.resolve_backup_index("nist-nvd2", "tok-123",
                 http_get_json: http_get_json
               )

      assert_received {:index_request, url, headers}
      assert url =~ "/v3/backup/nist-nvd2"
      assert {"authorization", "Bearer tok-123"} in headers
    end

    test "errors on an empty backup index" do
      http_get_json = fn _url, _headers -> {:ok, %{"data" => []}} end

      assert {:error, :empty_backup_index} =
               Acquisition.resolve_backup_index("vulncheck-kev", "tok",
                 http_get_json: http_get_json
               )
    end
  end

  describe "acquire_vulncheck/4 (full two-step, mocked HTTP)" do
    test "streams the presigned URL to disk with NO auth header, then extracts", %{root: _root} do
      test_pid = self()

      json = ~s([{"cveID":"CVE-2024-9999","vendorProject":"acme","product":"thing"}])
      zip_bytes = zip_bytes([{~c"vulncheck_known_exploited_vulnerabilities.json", json}])

      http_get_json = fn _url, _headers ->
        {:ok, %{"data" => [%{"url" => "https://s3.example/presigned.zip"}]}}
      end

      http_get = fn url, opts ->
        # The presigned S3 GET must carry no Authorization header.
        send(test_pid, {:download, url, opts})
        File.write!(opts[:into].path, zip_bytes)
        :ok
      end

      assert {:ok, acquired} =
               Acquisition.acquire_vulncheck("vulncheck-kev", "tok", "run-acq",
                 http_get_json: http_get_json,
                 http_get: http_get
               )

      assert acquired.format == :json

      assert File.exists?(
               Path.join(acquired.extracted_dir, "vulncheck_known_exploited_vulnerabilities.json")
             )

      assert_received {:download, "https://s3.example/presigned.zip", opts}
      refute Keyword.has_key?(opts, :headers)
    end
  end

  describe "download failures" do
    test "a failed VulnCheck index fetch removes the prepared run dir", %{root: root} do
      http_get_json = fn _url, _headers -> {:error, :timeout} end

      assert {:error, {:backup_index_failed, :timeout}} =
               Acquisition.acquire_vulncheck("nist-nvd2", "tok", "index-timeout",
                 http_get_json: http_get_json
               )

      refute File.exists?(Path.join([root, "nist-nvd2", "index-timeout"]))
    end

    test "rejects an HTTP error and removes the partial CISA file", %{root: root} do
      http_get = fn _url, opts ->
        File.write!(opts[:into].path, "gateway error")
        {:ok, %{status: 503}}
      end

      assert {:error, {:download_failed, {:http_status, 503}}} =
               Acquisition.acquire_cisa("https://example.invalid/cisa.json", "failed-run",
                 http_get: http_get
               )

      refute File.exists?(
               Path.join([root, "cisa-kev", "failed-run", "extracted", "cisa-kev.json"])
             )
    end
  end

  describe "default HTTP client" do
    test "req_opts uses the named Finch pool without connect_options" do
      opts = Acquisition.req_opts(30_000)
      assert Keyword.get(opts, :finch) == [name: ServiceRadar.Finch]
      assert Keyword.get(opts, :receive_timeout) == 30_000
      refute Keyword.has_key?(opts, :connect_options)
    end

    @tag :requires_app
    test "streams a successful response through the shared Finch pool" do
      body = ~s({"vulnerabilities":[]})
      {url, response_ref, stop} = start_http_server(body)

      on_exit(stop)

      assert {:ok, acquired} = Acquisition.acquire_cisa(url, "default-client-run")
      assert File.read!(Path.join(acquired.extracted_dir, "cisa-kev.json")) == body
      assert_receive {^response_ref, :served}, 5_000
    end
  end

  defp build_zip(root, entries) do
    zip_path = Path.join(root, "download-#{System.unique_integer([:positive])}.zip")
    File.mkdir_p!(Path.dirname(zip_path))
    {:ok, _} = :zip.create(String.to_charlist(zip_path), zip_entries(entries))
    zip_path
  end

  defp zip_bytes(entries) do
    {:ok, {_name, bytes}} = :zip.create(~c"in-memory.zip", zip_entries(entries), [:memory])
    bytes
  end

  defp zip_entries(entries) do
    Enum.map(entries, fn {name, content} -> {name, to_binary(content)} end)
  end

  defp to_binary(content) when is_binary(content), do: content

  defp start_http_server(body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    response_ref = make_ref()
    parent = self()
    pid = spawn(fn -> accept_http_requests(listener, body, parent, response_ref) end)

    stop = fn ->
      _ = :gen_tcp.close(listener)

      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end

    {"http://127.0.0.1:#{port}/cisa.json", response_ref, stop}
  end

  defp accept_http_requests(listener, body, parent, response_ref) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        served? =
          with {:ok, _request} <- :gen_tcp.recv(socket, 0, 5_000),
               :ok <- :gen_tcp.send(socket, http_response(body)) do
            true
          else
            _ -> false
          end

        _ = :gen_tcp.close(socket)

        if served? do
          send(parent, {response_ref, :served})
        end

        accept_http_requests(listener, body, parent, response_ref)

      {:error, :timeout} ->
        accept_http_requests(listener, body, parent, response_ref)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp http_response(body) do
    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end
end
