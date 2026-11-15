defmodule ServiceRadarNVR.Archive do
  @moduledoc """
  Copy one sealed local block to an S3-compatible bucket and retain a verified receipt.

  Core resolves the bucket credential and sends it inside one request over the
  pinned ingest channel. Only the archive task holds it, for that request: it is
  never written, logged, returned or passed to a supervisor's child arguments.
  One archive runs per NVR, through one Longshore client that is closed and
  drained before the response.

  Each object is written once with no-clobber, SSE-S3 and its SHA-256 checksum,
  bound by HEAD to the returned ETag, then read back in ranges whose digest must
  equal the local bytes. An object that already exists (412) is verified the same
  way and never overwritten. No PUT is retried and no other transport is tried:
  an unknown outcome fails the request, and a retry verifies whatever the
  provider retained. Only then is `archive-receipt.json` persisted beside the
  block, under the block's capacity allowance.

  The local block is kept. A receipt names verified remote copies; it is not a
  catalog entry, playback grant or deletion authority.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarNVR.Capacity
  alias ServiceRadarNVR.Publication
  alias ServiceRadarNVR.Reads
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  require Logger

  # The HTTP handler is killed at the request deadline. Before that the task
  # finishes provider work, drains its client and persists the receipt.
  @request_timeout_ms 120_000
  @await_timeout_ms 117_000
  @task_timeout_ms 115_000
  @provider_window_ms 75_000
  @drain_timeout_ms 5_000
  @max_object_bytes 16_777_216
  @readback_chunk_bytes 4_194_304

  def request_timeout_ms, do: @request_timeout_ms

  @doc "Validate and run one archive request body; returns the HTTP status and response body."
  def run(config, block_id, body) do
    result =
      with {:ok, request} <- parse(config, block_id, body),
           :ok <- ready(config.recovery_gate) do
        dispatch(request)
      end

    response(result)
  end

  defp parse(config, block_id, body) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, block_id),
      do: decode(config, block_id, body),
      else: {:error, :block_not_found}
  end

  defp decode(config, block_id, body) do
    with {:ok,
          %{
            "version" => 1,
            "storage_id" => storage_id,
            "recovery_generation" => generation,
            "destination" => destination,
            "credential" => credential
          } = document}
         when map_size(document) == 5 <- Jason.decode(body),
         # Canonical bytes leave no duplicate keys or alternative spellings to interpret.
         {:ok, ^body} <- CanonicalJSON.encode(document),
         true <- is_binary(storage_id) and storage_id == config.storage_id,
         true <- generation?(config.recovery_gate, generation),
         {:ok, target} <- target(destination),
         {:ok, secret} <- credential(credential) do
      client = Map.merge(target, Map.put(secret, :session_token, nil))

      {:ok,
       %{
         block_id: block_id,
         storage_id: storage_id,
         destination: destination,
         object_prefix: destination["object_prefix"],
         client: Map.merge(client, %{concurrency: 1, buffer_size: @max_object_bytes})
       }}
    else
      _ -> {:error, :invalid_archive_request}
    end
  end

  defp generation?(%{generation: generation}, value), do: is_binary(value) and value == generation
  defp generation?(_gate, _value), do: false

  defp target(%{"host" => host, "region" => region, "bucket" => bucket, "object_prefix" => prefix} = destination) do
    with {:ok, port} <- port(destination),
         {:ok, tls} <- transport(host),
         true <- region?(region) and dns_name?(bucket, 3, 63) and object_prefix?(prefix) do
      {:ok, %{host: host, port: port, tls: tls, region: region, bucket: bucket}}
    end
  end

  defp target(_destination), do: :error

  defp port(%{"port" => port} = destination) when map_size(destination) == 5 and is_integer(port) and port in 1..65_535,
    do: {:ok, port}

  defp port(destination) when map_size(destination) == 4, do: {:ok, 443}
  defp port(_destination), do: :error

  # Plaintext only for a numeric loopback peer, which is the only plaintext
  # target the client library accepts. Every other host is a DNS name over TLS.
  defp transport(host) when is_binary(host) and byte_size(host) <= 253 do
    cond do
      match?({:ok, {127, _, _, _}}, :inet.parse_ipv4strict_address(String.to_charlist(host))) -> {:ok, false}
      dns_name?(host, 3, 253) and String.contains?(host, ".") -> {:ok, true}
      true -> :error
    end
  end

  defp transport(_host), do: :error

  defp region?(value), do: is_binary(value) and byte_size(value) in 1..40 and Regex.match?(~r/\A[a-z0-9-]+\z/, value)

  defp object_prefix?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9_-](?:[a-z0-9\/_-]{0,126}[a-z0-9_-])?\z/, value)

  defp dns_name?(value, minimum, maximum) do
    is_binary(value) and byte_size(value) in minimum..maximum and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, value) and
      not Enum.any?(["..", ".-", "-."], &String.contains?(value, &1)) and
      Enum.all?(String.split(value, "."), &(byte_size(&1) <= 63)) and
      match?({:error, _}, :inet.parse_address(String.to_charlist(value)))
  end

  defp credential(%{"access_key_id" => access_key, "secret_access_key" => secret_key} = credential)
       when map_size(credential) == 2 do
    # The access key travels in the signed Authorization header, so it is
    # printable ASCII; the secret only keys the signature.
    if is_binary(access_key) and byte_size(access_key) in 1..256 and Regex.match?(~r/\A[!-~]+\z/, access_key) and
         is_binary(secret_key) and byte_size(secret_key) in 1..512 and String.valid?(secret_key),
       do: {:ok, %{access_key: access_key, secret_key: secret_key}},
       else: :error
  end

  defp credential(_credential), do: :error

  defp ready(gate) do
    case RecoveryGate.check(gate) do
      :ok -> :ok
      _ -> {:error, :archive_unavailable}
    end
  end

  # The request reaches the task as a message, so the credential never becomes
  # part of the task supervisor's child arguments.
  defp dispatch(request) do
    reply = :erlang.alias([:reply])

    try do
      case Task.Supervisor.start_child(ServiceRadarNVR.ArchiveTasks, fn -> execute(reply) end) do
        {:ok, pid} ->
          send(pid, {reply, request})
          await(pid, reply)

        {:error, :max_children} ->
          {:error, :archive_busy}

        {:error, _} ->
          {:error, :archive_unavailable}
      end
    catch
      :exit, _ -> {:error, :archive_unavailable}
    after
      :erlang.unalias(reply)
    end
  end

  defp await(pid, reply) do
    monitor = Process.monitor(pid)

    result =
      receive do
        {^reply, archived} -> archived
        {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, {:archive_local, :task, "task_exit"}}
      after
        @await_timeout_ms -> {:error, {:archive_local, :task, "deadline"}}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp execute(reply) do
    # The credential is held here only; hide it from process inspection and dumps.
    Process.flag(:sensitive, true)
    # A client that fails to start exits its linked caller; receive that instead.
    Process.flag(:trap_exit, true)
    {:ok, timer} = :timer.exit_after(@task_timeout_ms, :kill)
    deadline = System.monotonic_time(:millisecond) + @provider_window_ms

    try do
      receive do
        {^reply, request} ->
          result = archive(request, deadline)
          report(result)
          send(reply, {reply, result})
      after
        5_000 -> :ok
      end
    after
      :timer.cancel(timer)
    end
  end

  defp archive(request, deadline) do
    # Only the client start receives the credential; nothing else that can fail
    # with its arguments in an error report holds it.
    {client, request} = Map.pop(request, :client)

    with {:ok, objects, retained} <- local_block(request.block_id) do
      case retained do
        {:ok, bytes} -> retained_receipt(bytes, request, objects)
        {:error, :enoent} -> copy(client, request, objects, deadline)
        {:error, _} -> {:error, :archive_receipt_conflict}
      end
    end
  end

  # One verified read supplies the exact init file, the complete media file,
  # the canonical descriptor and any retained receipt.
  defp local_block(block_id) do
    read =
      Reads.run(fn ->
        with {:ok, storage, limits} <- Capacity.recovery_storage(),
             {:ok, snapshot} <- Blocks.inspect(storage, block_id, limits),
             {:ok, descriptor} <- Blocks.descriptor(snapshot),
             {:ok, init} <- Spool.read_init(snapshot),
             {:ok, media} <- Blocks.media(snapshot) do
          objects = [{"init.mp4", init}, {"media.m4s", media}, {"descriptor.json", descriptor}]
          {:ok, objects, Publication.inspect(storage, block_id, :archive_receipt, limits)}
        end
      end)

    case read do
      {:ok, objects, retained} -> {:ok, Enum.map(objects, &object/1), retained}
      {:error, reason} -> {:error, block_error(reason)}
    end
  end

  defp object({name, bytes}),
    do: %{name: name, bytes: bytes, size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}

  defp block_error(reason) when reason in [:enoent, :invalid_block_id], do: :block_not_found

  defp block_error(reason)
       when reason in [
              :nvr_read_capacity,
              :nvr_read_timeout,
              :nvr_read_unavailable,
              :nvr_recovery_closed,
              :nvr_storage_not_configured
            ], do: :archive_unavailable

  defp block_error(_reason), do: :block_not_sealed

  # A retained receipt is returned only when it re-encodes byte-for-byte from
  # this request's destination and the block just verified.
  defp retained_receipt(bytes, request, objects) do
    with {:ok, %{"objects" => entries, "verified_at_ms" => verified_at}} <- Jason.decode(bytes),
         true <- is_list(entries) and length(entries) == length(objects) and is_integer(verified_at),
         etags = Enum.map(entries, &(is_map(&1) and &1["etag"])),
         true <- Enum.all?(etags, &etag?/1),
         true <- encode_receipt(request, Enum.zip(objects, etags), verified_at) == {:ok, bytes} do
      {:ok, bytes}
    else
      _ -> {:error, :archive_receipt_conflict}
    end
  end

  defp copy(client, request, objects, deadline) do
    with true <- Enum.all?(objects, &(&1.size <= @max_object_bytes)) || {:error, :block_too_large},
         {:ok, session} <- open_session(client) do
      transferred =
        try do
          transfer_all(session, request, objects, deadline)
        after
          close_session(session)
        end

      with {:ok, etags} <- transferred,
           {:ok, bytes} <- encode_receipt(request, Enum.zip(objects, etags), System.os_time(:millisecond)),
           do: persist(request.block_id, bytes)
    end
  end

  defp open_session(client) do
    case ObjectStorageSession.start_link(config: client, drain_timeout_ms: @drain_timeout_ms) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, {:archive_local, :client, class(reason)}}
    end
  end

  # Session termination closes admission and drains native work before returning.
  defp close_session(session) do
    GenServer.stop(session, :normal, @drain_timeout_ms + 1_000)
  catch
    :exit, _ -> :ok
  end

  defp transfer_all(session, request, objects, deadline) do
    result =
      Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, etags} ->
        case transfer(session, object_key(request, object.name), object, deadline) do
          {:ok, etag} -> {:cont, {:ok, [etag | etags]}}
          {:error, stage, outcome} -> {:halt, {:error, {:archive_failed, stage, object.name, outcome}}}
        end
      end)

    with {:ok, etags} <- result, do: {:ok, Enum.reverse(etags)}
  end

  defp transfer(session, key, object, deadline) do
    options = %{no_clobber: true, encryption: :aes256, checksum: {:sha256, object.digest}}

    put = &ObjectStorageSession.put(session, key, object.bytes, options, &1)

    with {:ok, written} <- stored(call(deadline, put), object),
         head = &ObjectStorageSession.head(session, key, written, &1),
         {:ok, identity} <- described(call(deadline, head), written, object),
         :ok <- read_back(session, key, identity, object, deadline) do
      {:ok, identity.etag}
    end
  end

  defp stored({:ok, %{end: {:answered, %{status: 200, malformed: false} = answer}}, _stats}, object) do
    if answer.encryption == :aes256 and echoed?(answer.sha256, object.digest),
      do: identity(answer, :put),
      else: {:error, :put, "unattested_answer"}
  end

  # The object already exists and is never replaced: HEAD names it, readback decides.
  defp stored({:ok, %{end: {:answered, %{status: 412}}}, _stats}, _object), do: {:ok, %{etag: nil, version: nil}}
  defp stored(result, _object), do: {:error, :put, outcome(result)}

  defp described({:ok, %{end: {:answered, %{status: 200, malformed: false} = answer}}, _stats}, written, object) do
    with {:ok, identity} <- identity(answer, :head),
         true <-
           ((is_nil(written.etag) or written == identity) and answer.content_length == object.size and
              answer.encryption == :aes256 and echoed?(answer.sha256, object.digest)) ||
             {:error, :head, "metadata_mismatch"} do
      {:ok, identity}
    end
  end

  defp described(result, _written, _object), do: {:error, :head, outcome(result)}

  defp read_back(session, key, identity, object, deadline),
    do: read_back(session, key, identity, object, deadline, 0, :crypto.hash_init(:sha256))

  defp read_back(_session, _key, _identity, %{size: size} = object, _deadline, size, hash) do
    if :crypto.hash_final(hash) == object.digest, do: :ok, else: {:error, :readback, "digest_mismatch"}
  end

  defp read_back(session, key, identity, object, deadline, first, hash) do
    last = min(object.size - 1, first + @readback_chunk_bytes - 1)
    expected = last - first + 1

    case call(deadline, &ObjectStorageSession.get(session, key, {first, last}, identity, &1)) do
      {:ok, %{end: {:answered, %{status: 206, malformed: false} = answer}}, _stats} ->
        if identity(answer, :readback) == {:ok, identity} and
             answer.content_range == %{first: first, last: last, size: object.size} and
             is_binary(answer.body) and byte_size(answer.body) == expected and answer.body_len == expected,
           do: read_back(session, key, identity, object, deadline, last + 1, :crypto.hash_update(hash, answer.body)),
           else: {:error, :readback, "range_mismatch"}

      result ->
        {:error, :readback, outcome(result)}
    end
  end

  # Every operation is a single attempt bounded by the archive's provider window.
  defp call(deadline, submit) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        submit.(budget: %{timeout_ms: remaining}, call_timeout: remaining + @drain_timeout_ms)

      _ ->
        {:error, :deadline}
    end
  catch
    :exit, _ -> {:error, :client_exit}
  end

  defp identity(%{etag: etag, version: version}, stage) do
    if etag?(etag) and version?(version),
      do: {:ok, %{etag: etag, version: if(version == "null", do: nil, else: version)}},
      else: {:error, stage, "invalid_identity"}
  end

  defp etag?(etag), do: is_binary(etag) and byte_size(etag) in 3..256 and Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, etag)

  defp version?(version),
    do:
      is_nil(version) or
        (is_binary(version) and byte_size(version) in 1..1024 and Regex.match?(~r/\A[\x21-\x7e]+\z/, version))

  # A provider need not echo the checksum; when it does, it must match.
  defp echoed?(nil, _digest), do: true
  defp echoed?(echoed, digest), do: echoed == digest

  defp object_key(request, name), do: Enum.join([request.object_prefix, request.storage_id, request.block_id, name], "/")

  defp encode_receipt(request, verified, verified_at) do
    objects =
      Enum.map(verified, fn {object, etag} ->
        %{
          "name" => object.name,
          "key" => object_key(request, object.name),
          "length" => object.size,
          "sha256" => Base.encode16(object.digest, case: :lower),
          "etag" => etag
        }
      end)

    document = %{
      "version" => 1,
      "storage_id" => request.storage_id,
      "block_id" => request.block_id,
      "destination" => request.destination,
      "objects" => objects,
      "verified_at_ms" => verified_at
    }

    limit = Publication.max_bytes(:archive_receipt)

    case CanonicalJSON.encode(document) do
      {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
      _ -> {:error, {:archive_local, :receipt, "receipt_too_large"}}
    end
  end

  defp persist(block_id, bytes) do
    case Capacity.record_archive_receipt(block_id, bytes) do
      {:ok, ^bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:archive_local, :receipt, class(reason)}}
    end
  catch
    :exit, _ -> {:error, {:archive_local, :receipt, "capacity_unavailable"}}
  end

  # Outcome classes come from statuses and atoms only: never keys, credentials or bodies.
  defp outcome({:ok, %{end: {:answered, %{malformed: true}}}, _stats}), do: "malformed_answer"
  defp outcome({:ok, %{end: {:answered, %{status: status}}}, _stats}) when is_integer(status), do: "status_#{status}"

  defp outcome({:ok, %{end: {kind, cause}}, _stats}) when kind in [:not_sent, :unknown] and is_atom(cause),
    do: "#{kind}_#{cause}"

  defp outcome({:error, reason}), do: class(reason)
  defp outcome(_result), do: "unexpected_reply"

  defp class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp class(_reason), do: "error"

  defp report({:error, {:archive_failed, stage, object, outcome}}),
    do: Logger.warning("NVR archive failed: stage=#{stage} object=#{object} outcome=#{outcome}")

  defp report({:error, {:archive_local, stage, outcome}}),
    do: Logger.warning("NVR archive failed: stage=#{stage} outcome=#{outcome}")

  defp report(_result), do: :ok

  defp response({:ok, receipt}), do: {200, receipt}

  defp response({:error, {:archive_failed, stage, object, _outcome}}),
    do: {502, %{error: "archive_failed", stage: Atom.to_string(stage), object: object}}

  defp response({:error, :invalid_archive_request}), do: {400, %{error: "invalid_archive_request"}}
  defp response({:error, :block_not_found}), do: {404, %{error: "block_not_found"}}
  defp response({:error, :block_not_sealed}), do: {409, %{error: "block_not_sealed"}}
  defp response({:error, :archive_receipt_conflict}), do: {409, %{error: "archive_receipt_conflict"}}
  defp response({:error, :block_too_large}), do: {422, %{error: "block_too_large"}}
  defp response({:error, :archive_busy}), do: {503, %{error: "archive_busy"}}
  defp response({:error, _reason}), do: {503, %{error: "archive_unavailable"}}
end
