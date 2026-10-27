defmodule ServiceRadarCoreElx.CameraRecording.ProviderProbe do
  @moduledoc """
  Opt-in, one-shot S3 capability diagnostic for two newly provisioned buckets.

  Never starts with the application. The operator owns bucket/key creation and
  removal. This diagnostic only writes invented bytes under its fresh run prefix,
  journals exact cleanup authority before writes, and removes those objects and
  uploads. Results deliberately contain no URLs, credential material or provider
  response text. See build/media/provider-probe.md for invocation and recovery.
  """

  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP
  alias ServiceRadar.HTTP.EgressProxy

  @run_ms 900_000
  @cleanup_ms 180_000
  @request_ms 30_000
  @requests 80
  @cleanup_requests 30
  @total_bytes 64 * 1_024 * 1_024
  @part_bytes 5 * 1_024 * 1_024
  @management_bytes 16_384
  @conditional_headers [{"if-none-match", "*"}]
  @encryption_headers [{"x-amz-server-side-encryption", "AES256"}]

  def main do
    Logger.configure(level: :none)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)

    report =
      with {:ok, raw} <- read_input(System.get_env("VMS_PROBE_INPUT")),
           {:ok, config} <- configuration(raw),
           {:ok, report} <- run(config, System.get_env("VMS_PROBE_JOURNAL")) do
        report
      else
        _ -> %{status: :failed, checks: %{input: :invalid}}
      end

    IO.puts(Jason.encode!(report))
    System.halt(if(report.status == :passed, do: 0, else: 1))
  rescue
    _ ->
      IO.puts(~s({"status":"failed","checks":{"runtime":"failed"}}))
      System.halt(1)
  end

  def configuration(raw) do
    with %{
           "run_id" => run,
           "region" => region,
           "endpoint" => endpoint,
           "writer_a" => writer_a,
           "writer_b" => writer_b,
           "reader_a" => reader_a
         } <- raw,
         true <- is_binary(run) and Regex.match?(~r/^[a-f0-9]{32}$/, run),
         true <- is_binary(region) and Regex.match?(~r/^[a-z0-9-]{1,40}$/, region),
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path} <- URI.parse(endpoint),
         true <- is_binary(host) and path in [nil, "", "/"],
         true <- Enum.all?([writer_a, writer_b, reader_a], &credential?/1) do
      {:ok,
       %{
         run_id: run,
         region: region,
         endpoint: String.trim_trailing(endpoint, "/"),
         bucket_a: "sr-vms-probe-#{run}-a",
         bucket_b: "sr-vms-probe-#{run}-b",
         writer_a: writer_a,
         writer_b: writer_b,
         reader_a: reader_a,
         proxy: EgressProxy.from_env(),
         cacerts: :public_key.cacerts_get()
       }}
    else
      _ -> {:error, :invalid_input}
    end
  rescue
    _ -> {:error, :invalid_input}
  end

  def run(config, journal_path) when is_binary(journal_path) do
    state = %{
      config: config,
      journal_path: journal_path,
      objects: [],
      uploads: [],
      pending_uploads: [],
      unexpected_versions: [],
      requests: 0,
      bytes: 0,
      deadline: now() + @run_ms,
      checks: %{
        conditional_put: :not_tested,
        conditional_multipart: :not_tested,
        multipart_abort: :not_tested,
        explicit_sse_s3_put: :not_tested,
        explicit_sse_s3_multipart: :not_tested
      },
      failures: %{},
      request_limit: @requests,
      byte_limit: @total_bytes - 2 * 1_024 * 1_024,
      receipts: %{}
    }

    with {:ok, file} <- File.open(journal_path, [:write, :exclusive]),
         :ok <- File.close(file),
         :ok <- File.chmod(journal_path, 0o600),
         :ok <- journal(state) do
      state = execute_steps(state)
      diagnostic_requests = state.requests

      state =
        cleanup(%{
          state
          | deadline: now() + @cleanup_ms,
            request_limit: state.requests + @cleanup_requests,
            byte_limit: @total_bytes
        })

      clean =
        state.objects == [] and state.uploads == [] and state.pending_uploads == [] and state.unexpected_versions == []

      state = check(state, :cleanup, if(clean, do: :passed, else: :incomplete))
      :ok = journal(state)
      passed = Enum.all?(state.checks, fn {_, result} -> result == :passed end)

      {:ok,
       %{
         status: if(passed, do: :passed, else: :failed),
         checks: state.checks,
         failures: state.failures,
         requests: state.requests,
         diagnostic_requests: diagnostic_requests,
         cleanup_requests: state.requests - diagnostic_requests,
         body_budget_charged_bytes: state.bytes,
         cloud_ready: false,
         recorder_credentials: :unsupported,
         policy_enforcement: :not_tested,
         explicit_sse_s3: capability(state, [:explicit_sse_s3_put, :explicit_sse_s3_multipart]),
         atomic_no_overwrite: capability(state, [:conditional_put, :conditional_multipart]),
         object_lock: :not_tested
       }}
    end
  end

  def run(_, _), do: {:error, :invalid_journal}

  defp execute_steps(state) do
    Enum.reduce_while(
      [
        {:empty_buckets, &preflight/1},
        {:objects, &objects/1},
        {:private_access, &private_access/1},
        {:roles, &roles/1},
        {:range_identity_hash, &ranges/1},
        {:checksum_rejection, &checksum/1},
        {:multipart, &multipart/1},
        {:conditional_put, &conditional_put/1},
        {:conditional_multipart, &conditional_multipart/1},
        {:explicit_sse_s3_put, &explicit_put/1},
        {:explicit_sse_s3_multipart, &explicit_multipart/1}
      ],
      state,
      fn {name, operation}, current ->
        case operation.(current) do
          {:ok, next} ->
            {:cont, check(next, name, :passed)}

          {:error, reason, next} ->
            next = %{next | failures: Map.put(next.failures, name, safe_reason(reason))}
            status = failure(reason)
            {if(status in [:unsupported, :not_confirmed], do: :cont, else: :halt), check(next, name, status)}
        end
      end
    )
  end

  defp preflight(state) do
    Enum.reduce_while([:a, :b], {:ok, state}, fn bucket, {:ok, state} ->
      with {:ok, response, state} <- request(state, bucket, :writer, :get, nil, "list-type=2&max-keys=1"),
           {:ok, state} <- expect(state, response, [200]),
           {:ok, state} <- verify(state, String.contains?(response.body, "<KeyCount>0</KeyCount>"), :bucket_not_empty),
           {:ok, response, state} <- request(state, bucket, :writer, :get, nil, "versioning"),
           {:ok, state} <- expect(state, response, [200]),
           {:ok, state} <- verify(state, not String.contains?(response.body, "<Status>"), :versioned_bucket) do
        {:cont, {:ok, state}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp objects(state) do
    with {:ok, state} <- put(state, :a, "small", small()),
         {:ok, state} <- put(state, :b, "control", "invented second-purpose control"),
         {:ok, response, state} <- request(state, :a, :writer, :head, "small"),
         {:ok, state} <- expect(state, response, [200]),
         {:ok, state} <- verify(state, header(response, "content-length") == "65536", :size_mismatch),
         {:ok, state} <- verify(state, valid_etag?(header(response, "etag")), :missing_identity) do
      state = put_in(state.receipts[:small_etag], header(response, "etag"))
      {:ok, check(state, :encryption, encryption(response))}
    end
  end

  defp private_access(state) do
    with {:ok, r, state} <- request(state, :a, :anonymous, :get, "small"),
         {:ok, state} <- expect(state, r, [403]),
         {:ok, r, state} <- request(state, :a, :anonymous, :get, nil, "list-type=2&max-keys=1"),
         {:ok, state} <- expect(state, r, [403]) do
      denied_put(state, :a, :anonymous, "anonymous-write")
    end
  end

  defp roles(state) do
    with {:ok, r, state} <- request(state, :a, :reader, :head, "small"),
         {:ok, state} <- expect(state, r, [200]),
         {:ok, state} <- denied_put(state, :a, :reader, "reader-write"),
         {:ok, r, state} <- request(state, :a, :reader, :delete, "small"),
         {:ok, state} <- expect(state, r, [403]),
         {:ok, r, state} <- request(state, :a, :writer, :head, "small"),
         {:ok, state} <- expect(state, r, [200]),
         {:ok, r, state} <- request(state, :b, :writer, :head, "control"),
         {:ok, state} <- expect(state, r, [200]),
         {:ok, r, state} <- request(state, :b, :writer_a, :get, "control"),
         {:ok, state} <- expect(state, r, [403]) do
      denied_put(state, :b, :writer_a, "cross-write")
    end
  end

  defp ranges(state) do
    etag = state.receipts.small_etag

    with {:ok, r, state} <- range(state, "small", 0, 65_535, 65_536, etag),
         {:ok, state} <- verify(state, digest(r.body) == digest(small()), :hash_mismatch),
         {:ok, r, state} <- range(state, "small", 4096, 8191, 65_536, etag),
         {:ok, state} <- verify(state, r.body == binary_part(small(), 4096, 4096), :range_mismatch) do
      case range(state, "small", 0, 15, 65_536, ~s("invented-wrong-etag")) do
        {:error, {:http_status, 412}, state} -> {:ok, state}
        {:ok, _, state} -> {:error, :condition_not_enforced, state}
        {:error, _, state} -> {:error, :condition_not_proven, state}
      end
    end
  end

  defp checksum(state) do
    with {:ok, state} <- own(state, :a, "bad-checksum"),
         {:ok, r, state} <-
           request(state, :a, :writer, :put, "bad-checksum", nil, "invented bytes",
             headers: [{"content-md5", Base.encode64(<<0::128>>)}]
           ),
         {:ok, state} <-
           verify(state, r.status == 400 and String.contains?(r.body, "<Code>BadDigest</Code>"), :checksum_not_proven),
         {:ok, r, state} <- request(state, :a, :writer, :head, "bad-checksum") do
      with {:ok, state} <- expect(state, r, [404]), do: forget_object(state, :a, "bad-checksum")
    end
  end

  defp multipart(state) do
    with {:ok, upload, state} <- initiate(state, "multipart"),
         {:ok, first, state} <- part(state, upload, 1, part()),
         {:ok, last, state} <- part(state, upload, 2, tail()),
         {:ok, r, state} <-
           request(
             state,
             :a,
             :writer,
             :post,
             "multipart",
             upload_query(upload),
             "<CompleteMultipartUpload>" <> part_xml(1, first) <> part_xml(2, last) <> "</CompleteMultipartUpload>"
           ),
         {:ok, state} <- completed(state, r),
         {:ok, r, state} <- request(state, :a, :writer, :head, "multipart"),
         {:ok, state} <- expect(state, r, [200]),
         size = @part_bytes + 4096,
         {:ok, state} <- verify(state, header(r, "content-length") == to_string(size), :size_mismatch),
         state = check(state, :multipart_encryption, encryption(r)),
         etag = header(r, "etag"),
         {:ok, state} <- verify(state, valid_etag?(etag), :missing_identity),
         {:ok, r, state} <- range(state, "multipart", 0, size - 1, size, etag),
         {:ok, state} <- verify(state, digest(r.body) == digest(part() <> tail()), :hash_mismatch),
         {:ok, r, state} <- range(state, "multipart", @part_bytes - 16, @part_bytes + 15, size, etag),
         {:ok, state} <-
           verify(state, r.body == :binary.copy(<<90>>, 16) <> binary_part(tail(), 0, 16), :part_boundary_mismatch) do
      state = put_in(state.receipts[:multipart_etag], etag)
      {:ok, %{state | uploads: List.delete(state.uploads, upload)}}
    end
  end

  defp conditional_put(state) do
    with {:ok, r, state} <- request(state, :a, :writer, :put, "small", nil, contender(), headers: @conditional_headers),
         {:ok, state} <- precondition_failed(state, r),
         {:ok, _, state} <- verified_object(state, "small", small(), state.receipts.small_etag),
         {:ok, state} <- own(state, :a, "put-race"),
         {:ok, responses, state} <- race(state, "put-race", [{:put, nil, small()}, {:put, nil, contender()}]),
         {:ok, winner, state} <- winner(state, responses, :put),
         {:ok, _, state} <- verified_object(state, "put-race", Enum.at([small(), contender()], winner)) do
      {:ok, state}
    end
  end

  defp conditional_multipart(state) do
    with {:ok, upload, body, state} <- short_upload(state, "multipart", contender()),
         {:ok, r, state} <-
           request(state, :a, :writer, :post, upload.key, upload_query(upload), body, headers: @conditional_headers),
         {:ok, state} <- precondition_failed(state, r),
         {:ok, state} <- abort(state, upload),
         {:ok, _, state} <- verified_object(state, "multipart", part() <> tail(), state.receipts.multipart_etag),
         {:ok, left, left_body, state} <- short_upload(state, "multipart-race", small()),
         {:ok, right, right_body, state} <- short_upload(state, "multipart-race", contender()),
         {:ok, responses, state} <-
           race(state, "multipart-race", [
             {:post, upload_query(left), left_body},
             {:post, upload_query(right), right_body}
           ]),
         {:ok, winner, state} <- winner(state, responses, :post),
         uploads = [left, right],
         state = %{state | uploads: List.delete(state.uploads, Enum.at(uploads, winner))},
         {:ok, state} <- abort(state, Enum.at(uploads, 1 - winner)),
         {:ok, _, state} <- verified_object(state, "multipart-race", Enum.at([small(), contender()], winner)) do
      {:ok, check(state, :multipart_abort, :passed)}
    end
  end

  defp explicit_put(state) do
    with {:ok, state} <- own(state, :a, "explicit-put"),
         {:ok, r, state} <- request(state, :a, :writer, :put, "explicit-put", nil, small(), headers: @encryption_headers),
         {:ok, state} <- expect(state, r, [200]),
         {:ok, r, state} <- verified_object(state, "explicit-put", small()) do
      verify(state, encryption(r) == :passed, :encryption_not_confirmed)
    end
  end

  defp explicit_multipart(state) do
    with {:ok, upload, body, state} <- short_upload(state, "explicit-multipart", small(), @encryption_headers),
         {:ok, r, state} <- request(state, :a, :writer, :post, upload.key, upload_query(upload), body),
         {:ok, state} <- completed(state, r),
         state = %{state | uploads: List.delete(state.uploads, upload)},
         {:ok, r, state} <- verified_object(state, "explicit-multipart", small()) do
      verify(state, encryption(r) == :passed, :encryption_not_confirmed)
    end
  end

  defp short_upload(state, key, bytes, headers \\ []) do
    with {:ok, upload, state} <- initiate(state, key, headers),
         {:ok, etag, state} <- part(state, upload, 1, bytes) do
      {:ok, upload, "<CompleteMultipartUpload>" <> part_xml(1, etag) <> "</CompleteMultipartUpload>", state}
    end
  end

  defp verified_object(state, key, bytes, expected_etag \\ nil) do
    size = byte_size(bytes)

    with {:ok, head, state} <- request(state, :a, :reader, :head, key),
         {:ok, state} <- expect(state, head, [200]),
         etag = header(head, "etag"),
         {:ok, state} <-
           verify(state, valid_etag?(etag) and (is_nil(expected_etag) or etag == expected_etag), :identity_mismatch),
         {:ok, state} <- verify(state, header(head, "content-length") == to_string(size), :size_mismatch),
         {:ok, r, state} <- range(state, key, 0, size - 1, size, etag),
         {:ok, state} <- verify(state, digest(r.body) == digest(bytes), :hash_mismatch) do
      {:ok, head, state}
    end
  end

  defp completed(state, response) do
    verify(
      state,
      response.status == 200 and String.contains?(response.body, "<CompleteMultipartUploadResult") and
        not String.contains?(response.body, "<Error"),
      :multipart_completion_unproven
    )
  end

  defp precondition_failed(state, response) do
    verify(
      state,
      response.status == 412 and String.contains?(response.body, "<Code>PreconditionFailed</Code>"),
      if(response.status == 200, do: :conditional_write_not_enforced, else: :conditional_write_unproven)
    )
  end

  defp winner(state, responses, method) do
    outcomes =
      Enum.map(responses, fn
        {:ok, %{status: 200} = response} ->
          if(method == :put or match?({:ok, _}, completed(state, response)), do: :created, else: :invalid)

        {:ok, response} ->
          if(match?({:ok, _}, precondition_failed(state, response)), do: :rejected, else: :invalid)

        _ ->
          :invalid
      end)

    case outcomes do
      [:created, :rejected] -> {:ok, 0, state}
      [:rejected, :created] -> {:ok, 1, state}
      _ -> {:error, :conditional_race_unproven, state}
    end
  end

  defp initiate(state, key, headers \\ []) do
    owned = %{bucket: :a, key: key} in state.objects

    with {:ok, state} <- if(owned, do: {:ok, state}, else: own(state, :a, key)),
         state = %{state | pending_uploads: [key | state.pending_uploads]},
         :ok <- journal(state),
         {:ok, r, state} <- request(state, :a, :writer, :post, key, "uploads", nil, headers: headers),
         {:ok, state} <- expect(state, r, [200]) do
      # Admit bounded URL tokens, including every RFC3986 unreserved character.
      # Other XML/text forms stay pending for exact operator reconciliation.
      case Regex.run(~r/<UploadId>([A-Za-z0-9+\/=._~-]{1,1024})<\/UploadId>/, r.body) do
        [_, id] ->
          upload = %{key: key, id: id}
          state = %{state | pending_uploads: List.delete(state.pending_uploads, key), uploads: [upload | state.uploads]}
          :ok = journal(state)
          {:ok, upload, state}

        _ ->
          {:error, :missing_upload_receipt, state}
      end
    end
  end

  defp part(state, upload, number, body) do
    with {:ok, r, state} <-
           request(state, :a, :writer, :put, upload.key, upload_query(upload) <> "&partNumber=#{number}", body),
         {:ok, state} <- expect(state, r, [200]),
         etag = header(r, "etag"),
         {:ok, state} <-
           verify(state, is_binary(etag) and Regex.match?(~r/^"[a-zA-Z0-9-]+"$/, etag), :missing_part_receipt) do
      {:ok, etag, state}
    end
  end

  defp part_xml(number, etag), do: "<Part><PartNumber>#{number}</PartNumber><ETag>#{etag}</ETag></Part>"
  defp upload_query(upload), do: URI.encode_query(%{"uploadId" => upload.id})

  defp abort(state, upload) do
    with {:ok, r, state} <- request(state, :a, :writer, :delete, upload.key, upload_query(upload)),
         {:ok, state} <- expect(state, r, [204, 404]),
         {:ok, r, state} <- request(state, :a, :writer, :get, upload.key, upload_query(upload)),
         {:ok, state} <-
           verify(state, r.status == 404 and String.contains?(r.body, "<Code>NoSuchUpload</Code>"), :abort_not_proven) do
      {:ok, %{state | uploads: List.delete(state.uploads, upload)}}
    end
  end

  defp put(state, bucket, key, body) do
    with {:ok, state} <- own(state, bucket, key),
         {:ok, r, state} <- request(state, bucket, :writer, :put, key, nil, body) do
      expect(state, r, [200])
    end
  end

  defp denied_put(state, bucket, role, key) do
    with {:ok, state} <- own(state, bucket, key),
         {:ok, r, state} <- request(state, bucket, role, :put, key, nil, "invented denied write"),
         {:ok, state} <- expect(state, r, [403]),
         {:ok, r, state} <- request(state, bucket, :writer, :head, key) do
      with {:ok, state} <- expect(state, r, [404]), do: forget_object(state, bucket, key)
    end
  end

  defp own(state, bucket, key) do
    with {:ok, r, state} <- request(state, bucket, :writer, :head, key),
         {:ok, state} <- expect(state, r, [404]) do
      state = %{state | objects: [%{bucket: bucket, key: key} | state.objects]}
      :ok = journal(state)
      {:ok, state}
    end
  end

  defp forget_object(state, bucket, key) do
    state = %{state | objects: List.delete(state.objects, %{bucket: bucket, key: key})}
    :ok = journal(state)
    {:ok, state}
  end

  defp range(state, key, first, last, size, etag) do
    request(
      state,
      :a,
      :reader,
      :get,
      key,
      nil,
      nil,
      headers: [{"range", "bytes=#{first}-#{last}"}, {"if-match", etag}],
      range: {first, last, size, etag}
    )
  end

  defp request(state, bucket, role, method, key, query \\ nil, body \\ nil, options \\ []) do
    with {:ok, prepared, state} <- prepare(state, bucket, role, method, key, query, body, options) do
      finish(state, prepared, perform(state.config, prepared))
    end
  end

  # Only the caller reserves requests/bytes and owns the journal. The two tasks
  # hold signed requests, never independent copies of mutable cleanup authority.
  defp race(state, key, [{left_method, left_query, left_body}, {right_method, right_query, right_body}]) do
    with {:ok, left, state} <-
           prepare(state, :a, :writer, left_method, key, left_query, left_body, headers: @conditional_headers),
         {:ok, right, state} <-
           prepare(state, :a, :writer, right_method, key, right_query, right_body, headers: @conditional_headers) do
      {:ok, supervisor} = Task.Supervisor.start_link()

      results =
        try do
          supervisor
          |> Task.Supervisor.async_stream_nolink([left, right], &perform(state.config, &1),
            max_concurrency: 2,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.to_list()
        after
          Supervisor.stop(supervisor)
        end

      {responses, state} = Enum.map_reduce(Enum.zip([left, right], results), state, &collect_response/2)

      {:ok, responses, state}
    end
  end

  defp collect_response({prepared, result}, state) do
    case finish(state, prepared, task_response(result)) do
      {:ok, response, next} -> {{:ok, response}, next}
      {:error, reason, next} -> {{:error, reason}, next}
    end
  end

  defp task_response({:ok, response}), do: response
  defp task_response(_), do: {:error, :transport_error}

  defp prepare(state, bucket, role, method, key, query, body, options) do
    headers = Keyword.get(options, :headers, [])
    range = Keyword.get(options, :range)
    deadline = min(state.deadline, now() + @request_ms)
    sent = byte_size(body || "")
    limit = if(range, do: elem(range, 1) - elem(range, 0) + 1, else: @management_bytes)

    if deadline <= now() or state.requests >= state.request_limit or state.bytes + sent + limit > state.byte_limit do
      {:error, :budget_exhausted, state}
    else
      config = state.config
      url = object_url(config, bucket, key, query)
      credential = credential(config, bucket, role)
      headers = [{"accept-encoding", "identity"} | headers]
      headers = if(is_binary(body), do: [{"content-length", to_string(sent)} | headers], else: headers)
      headers = sign(config, credential, method, url, headers, body)
      # Reserve the entire response ceiling. A failed/aborted response still
      # consumed network bytes, even when its body is deliberately discarded.
      state = %{state | requests: state.requests + 1, bytes: state.bytes + sent + limit}

      {:ok,
       %{
         bucket: bucket,
         key: key,
         method: method,
         url: url,
         headers: headers,
         body: body,
         deadline: deadline,
         limit: limit,
         range: range
       }, state}
    end
  end

  defp perform(config, prepared) do
    timeout = prepared.deadline - now()

    if timeout > 0 do
      HTTP.request(
        config,
        prepared.method,
        prepared.url,
        prepared.headers,
        prepared.body,
        timeout,
        prepared.limit,
        prepared.range
      )
    else
      {:error, :request_timeout}
    end
  end

  defp finish(state, prepared, {:ok, response}) do
    state = %{state | bytes: state.bytes - prepared.limit + byte_size(response.body)}
    state = remember_version(state, prepared.bucket, prepared.key, prepared.method, response)
    {:ok, response, state}
  end

  defp finish(state, _, {:error, reason}), do: {:error, reason, state}

  defp object_url(config, bucket, key, query) do
    bucket_name = if(bucket == :a, do: config.bucket_a, else: config.bucket_b)
    path = if(key, do: "/#{config.run_id}/#{key}", else: "")
    "#{config.endpoint}/#{bucket_name}#{path}" <> if(query, do: "?#{query}", else: "")
  end

  defp sign(_, nil, _, _, headers, _), do: headers

  defp sign(config, credential, method, url, headers, body) do
    [access, secret] = Enum.map(["access_key_id", "secret_access_key"], &Map.fetch!(credential, &1))

    [
      method: method,
      url: url,
      headers: headers,
      body: body,
      aws_sigv4: [access_key_id: access, secret_access_key: secret, region: config.region, service: :s3]
    ]
    |> Req.new()
    |> Req.Steps.put_aws_sigv4()
    |> Req.get_headers_list()
  end

  defp cleanup(state) do
    state =
      Enum.reduce(state.uploads, state, fn upload, current ->
        case abort(current, upload) do
          {:ok, next} -> next
          {:error, _, next} -> next
        end
      end)

    Enum.reduce(state.objects, state, fn object, current ->
      # This probe admits only unversioned buckets. Recheck before deletion so
      # versioning drift cannot turn a delete marker into false cleanup proof.
      with {:ok, r, next} <- request(current, object.bucket, :writer, :get, nil, "versioning"),
           {:ok, next} <- expect(next, r, [200]),
           {:ok, next} <-
             verify(
               next,
               not String.contains?(r.body, "<Status>") and
                 not Enum.any?(next.unexpected_versions, &(&1.bucket == object.bucket)),
               :versioning_changed
             ),
           {:ok, r, next} <- request(next, object.bucket, :writer, :delete, object.key),
           {:ok, next} <- expect(next, r, [204, 404]),
           {:ok, r, next} <- request(next, object.bucket, :writer, :head, object.key),
           {:ok, next} <- expect(next, r, [404]) do
        %{next | objects: List.delete(next.objects, object)}
      else
        {:error, _, next} -> next
      end
    end)
  end

  defp journal(state) do
    bytes =
      Jason.encode!(%{
        version: 1,
        run_id: state.config.run_id,
        bucket_a: state.config.bucket_a,
        bucket_b: state.config.bucket_b,
        objects: state.objects,
        uploads: state.uploads,
        pending_uploads: state.pending_uploads,
        unexpected_versions: state.unexpected_versions
      })

    temporary = state.journal_path <> ".next"

    with :ok <- write_journal(temporary, bytes),
         :ok <- File.rename(temporary, state.journal_path) do
      # A synced file alone does not persist its renamed directory entry. Do
      # not issue a remote write until both the receipt and its name are durable.
      with_file(Path.dirname(state.journal_path), [:read, :directory], &:file.sync/1)
    end
  end

  defp write_journal(path, bytes) do
    with_file(path, [:write, :exclusive], fn device ->
      with :ok <- File.chmod(path, 0o600),
           :ok <- :file.write(device, bytes),
           do: :file.sync(device)
    end)
  end

  defp with_file(path, modes, fun) do
    case :file.open(String.to_charlist(path), [:raw, :binary | modes]) do
      {:ok, device} ->
        try do
          fun.(device)
        after
          :file.close(device)
        end

      {:error, _} = error ->
        error
    end
  end

  defp remember_version(state, bucket, key, method, response) when method in [:put, :post] do
    case header(response, "x-amz-version-id") do
      version when is_binary(version) and version not in ["", "null"] ->
        state = %{
          state
          | unexpected_versions: [%{bucket: bucket, key: key, version_id: version} | state.unexpected_versions]
        }

        :ok = journal(state)
        state

      _ ->
        state
    end
  end

  defp remember_version(state, _, _, _, _), do: state

  defp read_input(path) when is_binary(path) do
    with {:ok, %{size: size}} when size <= 16_384 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         do: Jason.decode(bytes)
  end

  defp read_input(_), do: {:error, :invalid_input}

  defp credential?(%{"access_key_id" => a, "secret_access_key" => s}),
    do: is_binary(a) and is_binary(s) and byte_size(a) in 1..256 and byte_size(s) in 1..256

  defp credential?(_), do: false
  defp credential(_, _, :anonymous), do: nil
  defp credential(config, _, :reader), do: config.reader_a
  defp credential(config, _, :writer_a), do: config.writer_a
  defp credential(config, :a, :writer), do: config.writer_a
  defp credential(config, :b, :writer), do: config.writer_b
  defp expect(state, response, statuses), do: verify(state, response.status in statuses, :unexpected_status)
  defp verify(state, true, _), do: {:ok, state}
  defp verify(state, _, reason), do: {:error, reason, state}
  defp check(state, name, result), do: put_in(state.checks[name], result)

  defp capability(state, names) do
    results = Enum.map(names, &Map.fetch!(state.checks, &1))
    Enum.find([:failed, :unsupported, :not_confirmed, :not_tested], :passed, &(&1 in results))
  end

  defp header(response, key) do
    case Req.Response.get_header(response, key) do
      [value] -> value
      _ -> nil
    end
  end

  defp valid_etag?(etag), do: is_binary(etag) and Regex.match?(~r/^"[a-zA-Z0-9-]+"$/, etag)

  defp encryption(response),
    do: if(header(response, "x-amz-server-side-encryption") == "AES256", do: :passed, else: :not_confirmed)

  defp failure(reason) when reason in [:checksum_not_proven, :condition_not_proven, :condition_not_enforced],
    do: :unsupported

  defp failure(:encryption_not_confirmed), do: :not_confirmed
  defp failure(_), do: :failed
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({:http_status, status}) when is_integer(status), do: %{http_status: status}
  defp safe_reason(_), do: :transport_error
  defp small, do: :binary.copy(<<0, 17, 34, 51, 68, 85, 102, 119>>, 8192)
  defp contender, do: :binary.copy(<<211>>, 65_536)
  defp part, do: :binary.copy(<<90>>, @part_bytes)
  defp tail, do: :binary.copy("tail", 1024)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes)
  defp now, do: System.monotonic_time(:millisecond)
end
