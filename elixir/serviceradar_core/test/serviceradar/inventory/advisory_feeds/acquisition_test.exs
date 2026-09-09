defmodule ServiceRadar.Inventory.AdvisoryFeeds.AcquisitionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.AdvisoryFeeds.Acquisition

  setup do
    root = Path.join(System.tmp_dir!(), "advisory-acq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
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

  test "Ubuntu publication validators accept 0/1/5 second skew and reject missing, changed, or stale pairs" do
    now = ~U[2026-09-02 18:10:00Z]

    response = fn second, etag ->
      %{
        status: 200,
        headers: %{
          "etag" => [etag],
          "last-modified" => ["Wed, 02 Sep 2026 18:05:0#{second} GMT"]
        }
      }
    end

    for skew <- [0, 1, 5] do
      download = %{osv: response.(0, "osv"), vex: response.(skew, "vex")}
      assert {:ok, _} = Acquisition.validate_ubuntu_publication(download, download, now)
    end

    too_wide = %{osv: response.(0, "osv"), vex: response.(6, "vex")}

    assert {:error, :publication_skew} =
             Acquisition.validate_ubuntu_publication(too_wide, too_wide, now)

    changed = %{osv: response.(0, "changed"), vex: response.(1, "vex")}
    original = %{osv: response.(0, "osv"), vex: response.(1, "vex")}

    assert {:error, {:validator_changed, :osv}} =
             Acquisition.validate_ubuntu_publication(original, changed, now)

    missing = put_in(original, [:osv, :headers], %{})

    assert {:error, :missing_etag} =
             Acquisition.validate_ubuntu_publication(missing, missing, now)

    missing_modified = put_in(original, [:vex, :headers], %{"etag" => ["vex"]})

    assert {:error, :missing_last_modified} =
             Acquisition.validate_ubuntu_publication(missing_modified, missing_modified, now)

    changed_modified =
      put_in(original, [:vex, :headers, "last-modified"], ["Wed, 02 Sep 2026 18:05:02 GMT"])

    assert {:error, {:validator_changed, :vex}} =
             Acquisition.validate_ubuntu_publication(original, changed_modified, now)

    future = %{osv: response.(0, "osv"), vex: response.(1, "vex")}

    assert {:error, :future_publication} =
             Acquisition.validate_ubuntu_publication(
               future,
               future,
               ~U[2026-09-02 17:59:59Z]
             )
  end

  test "compact pair rejects loopback downloads and redirect responses", %{root: root} do
    assert {:error, {:download_failed, :disallowed_host}} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://127.0.0.1/osv.tar.xz",
               "https://127.0.0.1/vex.tar.xz",
               "pair-loopback"
             )

    refute File.exists?(Path.join([root, "ubuntu-osv-vex", "pair-loopback"]))

    redirect = fn _url, _opts ->
      {:ok, %{status: 302, resolved_url: "https://127.0.0.1/private"}}
    end

    assert {:error, {:download_failed, {:http_status, 302}}} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv.tar.xz",
               "https://example.invalid/vex.tar.xz",
               "pair-redirect",
               http_get: redirect
             )

    refute File.exists?(Path.join([root, "ubuntu-osv-vex", "pair-redirect"]))
  end

  test "acquires the compact pair atomically with revalidated provenance and combined cap", %{
    root: root
  } do
    modified = "Wed, 02 Sep 2026 18:05:00 GMT"
    test_pid = self()

    http_get = fn url, opts ->
      body = if String.contains?(url, "/osv/"), do: "osv-body", else: "vex-body"
      Enum.into([body], opts[:into])

      {:ok,
       %{
         status: 200,
         resolved_url: url,
         headers: %{"etag" => ["\"#{body}\""], "last-modified" => [modified]}
       }}
    end

    http_head = fn url, opts ->
      body = if String.contains?(url, "/osv/"), do: "osv-body", else: "vex-body"
      send(test_pid, {:revalidated, url, opts[:headers] || []})
      {:ok, %{status: 200, headers: %{"etag" => ["\"#{body}\""], "last-modified" => [modified]}}}
    end

    assert {:ok, acquired} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv/feed.tar.xz",
               "https://example.invalid/vex/feed.tar.xz",
               "pair",
               http_get: http_get,
               http_head: http_head,
               now: ~U[2026-09-02 18:05:10Z],
               limits: %{compressed_bytes: 8},
               combined_compressed_bytes: 16
             )

    assert acquired.artifacts.osv.etag == "\"osv-body\""
    assert acquired.artifacts.vex.etag == "\"vex-body\""
    assert byte_size(acquired.generation_provenance) == 64

    assert acquired.generation_provenance ==
             Acquisition.combined_generation_provenance(acquired.artifacts)

    refute acquired.generation_provenance ==
             Acquisition.combined_generation_provenance(
               put_in(acquired.artifacts, [:osv, :final_url], "https://mirror.example/other")
             )

    refute acquired.generation_provenance ==
             Acquisition.combined_generation_provenance(
               update_in(acquired.artifacts, [:vex, :bytes], &(&1 + 1))
             )

    assert File.read!(acquired.osv_path) == "osv-body"
    assert File.read!(acquired.vex_path) == "vex-body"

    # The revalidation HEAD is unconditional: no If-Match/If-Unmodified-Since
    # preconditions, so a publication that rolls mid-download surfaces as
    # {:validator_changed, _} instead of {:revalidation_status, 412}.
    assert_received {:revalidated, _, []}

    assert {:error, {:download_failed, {:archive_limit_exceeded, :compressed_bytes}}} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv/feed.tar.xz",
               "https://example.invalid/vex/feed.tar.xz",
               "pair-file-too-large",
               http_get: http_get,
               http_head: http_head,
               now: ~U[2026-09-02 18:05:10Z],
               limits: %{compressed_bytes: 7}
             )

    refute File.exists?(Path.join([root, "ubuntu-osv-vex", "pair-file-too-large"]))
    assert_received {:revalidated, _, []}

    assert {:error, {:archive_limit_exceeded, :combined_compressed_bytes}} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv/feed.tar.xz",
               "https://example.invalid/vex/feed.tar.xz",
               "pair-too-large",
               http_get: http_get,
               http_head: http_head,
               now: ~U[2026-09-02 18:05:10Z],
               combined_compressed_bytes: 8
             )

    refute File.exists?(Path.join([root, "ubuntu-osv-vex", "pair-too-large"]))
  end

  test "re-acquires the pair when the publication rolls mid-download", %{root: _root} do
    modified = "Wed, 02 Sep 2026 18:05:00 GMT"
    test_pid = self()

    # Downloads run in concurrent tasks, so the round trip count lives in an
    # Agent: the first GET round pins v1, the origin publishes v2 before the
    # HEAD, and the re-acquired round pins v2.
    {:ok, gets} = Agent.start_link(fn -> 0 end)

    http_get = fn url, opts ->
      n = Agent.get_and_update(gets, fn n -> {n, n + 1} end)
      body = if n < 2, do: "v1", else: "v2"
      Enum.into([body], opts[:into])

      {:ok,
       %{
         status: 200,
         resolved_url: url,
         headers: %{"etag" => ["\"#{body}\""], "last-modified" => [modified]}
       }}
    end

    http_head = fn url, opts ->
      send(test_pid, {:revalidated, url, opts[:headers] || []})

      {:ok, %{status: 200, headers: %{"etag" => ["\"v2\""], "last-modified" => [modified]}}}
    end

    assert {:ok, acquired} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv/feed.tar.xz",
               "https://example.invalid/vex/feed.tar.xz",
               "pair-roll",
               http_get: http_get,
               http_head: http_head,
               now: ~U[2026-09-02 18:05:10Z]
             )

    # Settled on v2: both artifacts carry the revalidated publication.
    assert acquired.artifacts.osv.etag == "\"v2\""
    assert acquired.artifacts.vex.etag == "\"v2\""

    # Two full download rounds (osv+vex each), and every HEAD unconditional.
    assert Agent.get(gets, & &1) == 4
    assert_received {:revalidated, _, []}
    assert_received {:revalidated, _, []}
    assert_received {:revalidated, _, []}
    assert_received {:revalidated, _, []}
  end

  test "fails bounded when the publication keeps rolling", %{root: root} do
    modified = "Wed, 02 Sep 2026 18:05:00 GMT"

    # Every GET pins a fresh etag the HEAD never matches: the publication
    # rolls faster than one download round, so acquisition must give up
    # instead of re-acquiring forever.
    {:ok, gets} = Agent.start_link(fn -> 0 end)

    http_get = fn url, opts ->
      n = Agent.get_and_update(gets, fn n -> {n, n + 1} end)
      Enum.into(["v#{n}"], opts[:into])

      {:ok,
       %{
         status: 200,
         resolved_url: url,
         headers: %{"etag" => ["\"v#{n}\""], "last-modified" => [modified]}
       }}
    end

    http_head = fn _url, _opts ->
      {:ok, %{status: 200, headers: %{"etag" => ["\"head\""], "last-modified" => [modified]}}}
    end

    assert {:error, {:validator_changed, :osv}} =
             Acquisition.acquire_ubuntu_pair(
               "ubuntu-osv-vex",
               "https://example.invalid/osv/feed.tar.xz",
               "https://example.invalid/vex/feed.tar.xz",
               "pair-roll-forever",
               http_get: http_get,
               http_head: http_head,
               now: ~U[2026-09-02 18:05:10Z]
             )

    # Bounded: 3 rounds x 2 files, then the run dir is cleaned up.
    assert Agent.get(gets, & &1) == 6
    refute File.exists?(Path.join([root, "ubuntu-osv-vex", "pair-roll-forever"]))
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

    test "a transport timeout maps to download_failed and removes the partial CISA file", %{
      root: root
    } do
      http_get = fn _url, _opts -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, {:download_failed, %Req.TransportError{reason: :timeout}}} =
               Acquisition.acquire_cisa("https://example.invalid/cisa.json", "timeout-run",
                 http_get: http_get
               )

      refute File.exists?(
               Path.join([root, "cisa-kev", "timeout-run", "extracted", "cisa-kev.json"])
             )
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
