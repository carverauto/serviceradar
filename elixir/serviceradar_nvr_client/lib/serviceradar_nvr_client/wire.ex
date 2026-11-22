defmodule ServiceRadarNVRClient.Wire do
  @moduledoc false
  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarRecordingMetadata.Descriptor

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @max_ticks 9_223_372_036_854_775_807
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @dns_name ~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/
  @region ~r/\A[a-z0-9-]{1,40}\z/
  @object_prefix ~r/\A[a-z0-9_-](?:[a-z0-9\/_-]{0,126}[a-z0-9_-])?\z/
  @max_archive_request 8_192
  @max_archive_object 16_777_216
  @archive_objects ["descriptor.json", "init.mp4", "media.m4s"]

  def header(
        %{
          "version" => 1,
          "storage_id" => storage,
          "recovery_generation" => generation,
          "identity" => identity,
          "clock_epoch" => epoch
        } = header
      ) do
    clock = %{
      "clock_epoch" => epoch,
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    with true <- map_size(header) == 5 and uuid?(storage) and uuid?(generation),
         true <- is_map(identity) and not Map.has_key?(identity, "clock"),
         true <- Descriptor.valid_identity?(Map.put(identity, "clock", clock)),
         {:ok, json} <- CanonicalJSON.encode(header),
         true <- byte_size(json) in 1..1024 do
      {:ok, <<byte_size(json)::32, json::binary>>}
    else
      _ -> {:error, :invalid_ingest_header}
    end
  end

  def header(_), do: {:error, :invalid_ingest_header}

  def unit(%{payload: bytes, sequence: sequence, pts: pts, dts: dts})
      when is_binary(bytes) and byte_size(bytes) in 1..1_048_576 and sequence in 0..18_446_744_073_709_551_615 and
             pts in 0..@max_ticks and dts in 0..@max_ticks,
      do: {:ok, <<byte_size(bytes)::32, sequence::64, pts::64, dts::64, bytes::binary>>}

  def unit(_), do: {:error, :invalid_ingest_unit}

  def receipt(bytes, %{"storage_id" => storage, "identity" => identity}) do
    with {:ok, %{"version" => 1, "status" => "sealed_local", "storage_id" => ^storage, "block_ids" => ids} = value} <-
           Jason.decode(bytes),
         true <- map_size(value) == 4 and is_list(ids) and length(ids) in 1..256,
         true <- identity["block_sequence"] + length(ids) - 1 <= @max_ticks,
         expected =
           Enum.map(0..(length(ids) - 1), fn index ->
             Descriptor.block_key(Map.put(identity, "block_sequence", identity["block_sequence"] + index))
           end),
         true <- ids == expected do
      {:ok, %{storage_id: storage, block_ids: ids, status: :sealed_local}}
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  def archive_request(
        block_id,
        %{
          "version" => 1,
          "storage_id" => storage,
          "recovery_generation" => generation,
          "destination" => destination,
          "credential" => credential
        } = request
      ) do
    with true <- map_size(request) == 5 and matches?(block_id, @hex64) and uuid?(storage) and uuid?(generation),
         true <- destination?(destination) and credential?(credential),
         {:ok, json} <- CanonicalJSON.encode(request),
         true <- byte_size(json) <= @max_archive_request do
      {:ok, json}
    else
      _ -> {:error, :invalid_archive_request}
    end
  end

  def archive_request(_, _), do: {:error, :invalid_archive_request}

  def archive_receipt(bytes, block_id, %{"storage_id" => storage, "destination" => destination}) do
    prefix = Enum.join([destination["object_prefix"], storage, block_id], "/") <> "/"

    with {:ok,
          %{
            "version" => 1,
            "storage_id" => ^storage,
            "block_id" => ^block_id,
            "destination" => ^destination,
            "objects" => objects,
            "verified_at_ms" => verified_at
          } = receipt} <- Jason.decode(bytes),
         true <- map_size(receipt) == 6 and is_integer(verified_at) and verified_at > 0,
         true <- is_list(objects),
         true <- objects |> Enum.map(&archive_object(&1, prefix)) |> Enum.sort() == @archive_objects do
      {:ok, receipt}
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  def block_id(block_id), do: if(matches?(block_id, @hex64), do: :ok, else: {:error, :invalid_descriptor_request})

  # Only the exact canonical bytes are accepted, so the caller's re-encoding,
  # and the digest Core freezes, are the NVR's bytes.
  def descriptor(bytes, block_id) do
    with {:ok, descriptor} <- Jason.decode(bytes),
         {:ok, ^bytes} <- Descriptor.encode(descriptor),
         true <- Descriptor.block_key(descriptor["identity"]) == block_id do
      {:ok, descriptor}
    else
      _ -> {:error, :invalid_descriptor_response}
    end
  end

  def read_request(block_id, descriptor_sha256, selector, %{length: length, sha256: sha256} = expected)
      when map_size(expected) == 2 do
    with true <- matches?(block_id, @hex64) and matches?(descriptor_sha256, @hex64) and matches?(sha256, @hex64),
         {:ok, object, limit} <- media_object(selector),
         true <- is_integer(length) and length in 1..limit do
      {:ok, "/v1/blocks/" <> block_id <> "/" <> object <> "?descriptor_sha256=" <> descriptor_sha256}
    else
      _ -> {:error, :invalid_read_request}
    end
  end

  def read_request(_block_id, _descriptor_sha256, _selector, _expected), do: {:error, :invalid_read_request}

  # The fragment bound is the playback read path's (design D4); init is the descriptor's.
  defp media_object(:init), do: {:ok, "init", 1_048_576}

  defp media_object({:fragment, index}) when is_integer(index) and index in 0..255,
    do: {:ok, "fragments/" <> Integer.to_string(index), 4_194_304}

  defp media_object(_selector), do: :error

  def media(bytes, %{length: length, sha256: sha256}) do
    if byte_size(bytes) == length and Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256,
      do: {:ok, bytes},
      else: {:error, :integrity_mismatch}
  end

  # 409 is the NVR's answer for a block whose seal or selected bytes no longer
  # verify, or whose descriptor is not the one frozen: the local copy is not the
  # cataloged block.
  def read_refusal(404, _body), do: {:error, :not_found}
  def read_refusal(409, _body), do: {:error, :integrity_mismatch}
  def read_refusal(503, _body), do: {:error, :unavailable}
  def read_refusal(status, body), do: {:error, {:read_status, status, error_body(body)}}

  @block_states %{"sealed" => :sealed, "incomplete" => :incomplete, "unresolved" => :unresolved, "absent" => :absent}
  @gate_states %{"ready" => :ready, "closed" => :closed}
  @inventory_states %{
    "ready" => :ready,
    "rebuilding" => :rebuilding,
    "mismatch" => :mismatch,
    "unavailable" => :unavailable
  }
  @capacity_keys %{
    "available_bytes" => :available_bytes,
    "blocks" => :blocks,
    "max_blocks" => :max_blocks,
    "max_spool_bytes" => :max_spool_bytes,
    "reservations" => :reservations,
    "reserve_bytes" => :reserve_bytes,
    "reserved_bytes" => :reserved_bytes,
    "used_bytes" => :used_bytes
  }

  def lookup_request(block_ids) when is_list(block_ids) and length(block_ids) in 1..50 do
    if Enum.all?(block_ids, &matches?(&1, @hex64)) and length(Enum.uniq(block_ids)) == length(block_ids),
      do: CanonicalJSON.encode(%{"block_ids" => block_ids}),
      else: {:error, :invalid_lookup_request}
  end

  def lookup_request(_block_ids), do: {:error, :invalid_lookup_request}

  # A lookup answer must report exactly the requested blocks, in order.
  def lookup(bytes, block_ids) do
    with {:ok, %{"storage_id" => storage_id, "blocks" => blocks}} <- block_list(bytes, 3),
         true <- Enum.map(blocks, & &1.block_id) == block_ids do
      {:ok, %{storage_id: storage_id, blocks: blocks}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  # A ledger page holds ascending block IDs after `after_id` and names the last
  # one as `next_after` when it is full, nil when it is the last page.
  def block_page(bytes, after_id, limit) do
    with {:ok, %{"storage_id" => storage_id, "blocks" => blocks, "next_after" => next_after}} <- block_list(bytes, 4),
         ids = Enum.map(blocks, & &1.block_id),
         true <- length(ids) <= limit and ids == Enum.sort(Enum.uniq(ids)),
         true <- is_nil(after_id) or Enum.all?(ids, &(&1 > after_id)),
         true <- next_after == if(length(ids) == limit, do: List.last(ids)) do
      {:ok, %{storage_id: storage_id, blocks: blocks, next_after: next_after}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp block_list(bytes, keys) do
    with {:ok, %{"version" => 1, "storage_id" => storage_id, "blocks" => blocks} = list} <- Jason.decode(bytes),
         true <- map_size(list) == keys and uuid?(storage_id) and is_list(blocks),
         decoded = Enum.map(blocks, &block_state/1),
         false <- Enum.member?(decoded, :error) do
      {:ok, Map.put(list, "blocks", decoded)}
    else
      _ -> :error
    end
  end

  defp block_state(%{"block_id" => id, "state" => state, "writing" => writing, "bytes" => bytes} = block)
       when is_map_key(@block_states, state) and is_boolean(writing) do
    digest = Map.get(block, "descriptor_sha256")
    reason = Map.get(block, "reason")

    if matches?(id, @hex64) and map_size(block) == 4 + present(digest) + present(reason) and
         state_fields?(state, digest, reason, bytes) do
      %{
        block_id: id,
        state: Map.fetch!(@block_states, state),
        writing: writing,
        bytes: bytes,
        descriptor_sha256: digest,
        reason: reason
      }
    else
      :error
    end
  end

  defp block_state(_block), do: :error

  # A descriptor digest exactly when sealed, a reason exactly when unresolved,
  # a byte count when sealed or incomplete, optional when unresolved, nil when absent.
  defp state_fields?("sealed", digest, nil, bytes), do: matches?(digest, @hex64) and nonnegative?(bytes)
  defp state_fields?("unresolved", nil, reason, bytes), do: bounded_text?(reason, 64) and counted?(bytes)
  defp state_fields?("incomplete", nil, nil, bytes), do: nonnegative?(bytes)
  defp state_fields?("absent", nil, nil, nil), do: true
  defp state_fields?(_state, _digest, _reason, _bytes), do: false

  defp counted?(bytes), do: is_nil(bytes) or nonnegative?(bytes)

  defp present(nil), do: 0
  defp present(_value), do: 1

  def member_status(bytes) do
    with {:ok,
          %{
            "version" => 1,
            "storage_id" => storage_id,
            "recovery" => %{"state" => gate, "generation" => generation} = recovery,
            "inventory" => inventory,
            "capacity" => capacity,
            "max_sessions" => sessions,
            "archive_busy" => busy,
            "release" => release
          } = status} <- Jason.decode(bytes),
         true <- map_size(status) == 8 and map_size(recovery) == 2,
         true <- member_identity?(storage_id, gate, generation) and capacity?(capacity, inventory),
         true <- is_integer(sessions) and sessions > 0 and is_boolean(busy) and bounded_text?(release, 64) do
      {:ok,
       %{
         storage_id: storage_id,
         recovery: %{state: Map.fetch!(@gate_states, gate), generation: generation},
         inventory: Map.fetch!(@inventory_states, inventory),
         capacity: capacity && Map.new(capacity, fn {key, value} -> {Map.fetch!(@capacity_keys, key), value} end),
         max_sessions: sessions,
         archive_busy: busy,
         release: release
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp member_identity?(storage_id, gate, generation) do
    (is_nil(storage_id) or uuid?(storage_id)) and is_map_key(@gate_states, gate) and
      (is_nil(generation) or uuid?(generation))
  end

  defp capacity?(nil, inventory), do: inventory in ["rebuilding", "unavailable"]

  defp capacity?(%{} = capacity, inventory) do
    inventory in ["ready", "mismatch"] and Enum.sort(Map.keys(capacity)) == Enum.sort(Map.keys(@capacity_keys)) and
      Enum.all?(Map.values(capacity), &nonnegative?/1)
  end

  defp capacity?(_capacity, _inventory), do: false

  defp nonnegative?(value), do: is_integer(value) and value >= 0

  def error_body(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = error} -> error
      _ -> %{}
    end
  end

  defp archive_object(%{"name" => name, "key" => key, "length" => size, "sha256" => sha, "etag" => tag} = entry, prefix) do
    if map_size(entry) == 5 and is_binary(name) and key == prefix <> name and size in 1..@max_archive_object and
         matches?(sha, @hex64) and is_binary(tag) and byte_size(tag) in 1..1024,
       do: name
  end

  defp archive_object(_, _), do: nil

  defp destination?(%{"host" => host, "region" => region, "bucket" => bucket, "object_prefix" => prefix} = destination) do
    port?(destination) and dns_name?(host, 1, 253) and matches?(region, @region) and
      dns_name?(bucket, 3, 63) and matches?(prefix, @object_prefix)
  end

  defp destination?(_), do: false

  # The provider port defaults to 443 and is named only for a loopback peer.
  defp port?(%{"port" => port} = destination), do: map_size(destination) == 5 and is_integer(port) and port in 1..65_535
  defp port?(destination), do: map_size(destination) == 4

  defp credential?(%{"access_key_id" => access_key_id, "secret_access_key" => secret_access_key} = credential) do
    map_size(credential) == 2 and secret_string?(access_key_id, 256) and secret_string?(secret_access_key, 512)
  end

  defp credential?(_), do: false

  defp bounded_text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.printable?(value)

  defp secret_string?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)

  defp dns_name?(value, minimum, maximum),
    do: is_binary(value) and byte_size(value) in minimum..maximum and Regex.match?(@dns_name, value)

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
