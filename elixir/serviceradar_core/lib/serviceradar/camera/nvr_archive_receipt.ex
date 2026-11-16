defmodule ServiceRadar.Camera.NVRArchiveReceipt do
  @moduledoc """
  Append-only Core record of a readback-verified NVR archive copy.

  Each record binds `(storage_id, block_key, archive_binding_id)` to the exact
  canonical receipt bytes (`<= 8 KiB`, receipt version 1 or 2), SHA-256 digest,
  parsed object list (`name`, `key`, `length`, `sha256`, `etag`, and optional
  nullable `version_id` for receipt v2) and `verified_at` timestamp.
  Identical receipt bytes return the retained row idempotently; differing bytes
  are refused and logged. There are no update or destroy actions.

  A receipt records verified object readback only. It is not archive publication,
  not a qualified archive proof, and not authority to reclaim local media.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query
  require Logger

  @max_receipt_bytes 8192
  @max_version_id_bytes 1024
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @printable_ascii ~r/\A[\x21-\x7e]+\z/
  @system_actor SystemActor.system(:camera_nvr_archive_receipt)

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}

  postgres do
    table "camera_nvr_archive_receipts"
    schema "platform"
    repo ServiceRadar.Repo

    identity_index_names archive_copy: "camera_nvr_archive_receipts_copy_index"

    custom_indexes do
      index [:recording_block_id],
        name: "camera_nvr_archive_receipts_block_index",
        where: "recording_block_id IS NOT NULL"

      index [:block_key, :storage_id],
        name: "camera_nvr_archive_receipts_lookup_index"
    end

    references do
      reference :archive_binding,
        on_delete: :restrict,
        name: "camera_nvr_archive_receipts_binding_fkey"

      reference :recording_block,
        on_delete: :restrict,
        name: "camera_nvr_archive_receipts_block_fkey"
    end

    check_constraints do
      check_constraint :receipt_bytes, "camera_nvr_archive_receipts_bounds",
        check: """
        octet_length(receipt_bytes) BETWEEN 1 AND 8192 AND
        block_key ~ '^[0-9a-f]{64}$' AND
        destination_sha256 ~ '^[0-9a-f]{64}$' AND
        receipt_sha256 ~ '^[0-9a-f]{64}$' AND
        cardinality(objects) >= 1
        """
    end
  end

  code_interface do
    define :record, action: :record, args: [:archive_binding_id, :receipt_bytes]
  end

  actions do
    defaults [:read]

    create :record do
      accept []
      argument :archive_binding_id, :uuid, allow_nil?: false
      argument :receipt_bytes, :binary, allow_nil?: false
      argument :recording_block_id, :uuid, allow_nil?: true

      upsert? true
      upsert_identity :archive_copy
      upsert_fields []

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.before_action(&prepare_receipt/1)
        |> Ash.Changeset.after_action(&verify_idempotent_or_refuse/2)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :storage_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :block_key, :string do
      allow_nil? false
      public? true
      constraints match: @hex64
    end

    attribute :archive_binding_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :destination_sha256, :string do
      allow_nil? false
      public? true
      constraints match: @hex64
    end

    attribute :recording_block_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :receipt_bytes, :binary do
      allow_nil? false
      public? true
    end

    attribute :receipt_sha256, :string do
      allow_nil? false
      public? true
      constraints match: @hex64
    end

    attribute :objects, {:array, :map} do
      allow_nil? false
      public? true
    end

    attribute :verified_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :recorded_at, public?: true
  end

  relationships do
    belongs_to :archive_binding, ArchiveBinding do
      allow_nil? false
      public? true
      define_attribute? false
      source_attribute :archive_binding_id
    end

    belongs_to :recording_block, RecordingBlock do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :recording_block_id
    end
  end

  identities do
    identity :archive_copy, [:storage_id, :block_key, :archive_binding_id]
  end

  @doc """
  Parses and validates canonical NVR archive receipt JSON (`<= 8 KiB`) without DB I/O.
  """
  @spec parse_receipt_bytes(binary()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def parse_receipt_bytes(receipt_bytes)
      when is_binary(receipt_bytes) and byte_size(receipt_bytes) in 1..@max_receipt_bytes do
    with {:ok, payload} <- decode_json_receipt(receipt_bytes),
         {:ok, version} <- parse_version(payload),
         {:ok, storage_id} <- parse_storage_id(payload),
         {:ok, block_key} <- parse_block_key(payload),
         {:ok, verified_at} <- parse_verified_at(payload),
         {:ok, objects} <- parse_objects(payload),
         {:ok, destination_meta} <- parse_optional_destination(payload) do
      {:ok,
       %{
         version: version,
         storage_id: storage_id,
         block_key: block_key,
         verified_at: verified_at,
         objects: objects,
         receipt_sha256: :sha256 |> :crypto.hash(receipt_bytes) |> Base.encode16(case: :lower),
         destination: destination_meta
       }}
    end
  end

  def parse_receipt_bytes(receipt_bytes) when is_binary(receipt_bytes) do
    {:error, {:receipt_bytes, "must be 1..8192 bytes"}}
  end

  def parse_receipt_bytes(_) do
    {:error, {:receipt_bytes, "must be binary receipt bytes"}}
  end

  defp prepare_receipt(changeset) do
    binding_id = Ash.Changeset.get_argument(changeset, :archive_binding_id)
    receipt_bytes = Ash.Changeset.get_argument(changeset, :receipt_bytes)
    explicit_block_id = Ash.Changeset.get_argument(changeset, :recording_block_id)
    loaders = Map.get(changeset.context, :receipt_loaders, %{})

    with {:ok, parsed} <- parse_receipt_bytes(receipt_bytes),
         {:ok, binding} <- load_binding(binding_id, loaders),
         :ok <- verify_binding_destination(binding, parsed.destination),
         {:ok, resolved_block_id} <-
           resolve_recording_block_id(
             explicit_block_id,
             parsed.storage_id,
             parsed.block_key,
             loaders
           ) do
      Ash.Changeset.force_change_attributes(changeset, %{
        storage_id: parsed.storage_id,
        block_key: parsed.block_key,
        archive_binding_id: binding.id,
        destination_sha256: binding.destination_sha256,
        recording_block_id: resolved_block_id,
        receipt_bytes: receipt_bytes,
        receipt_sha256: parsed.receipt_sha256,
        objects: parsed.objects,
        verified_at: parsed.verified_at
      })
    else
      {:error, {field, message}} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: field, message: message)
        )
    end
  end

  defp verify_idempotent_or_refuse(submitted, retained) do
    if Ash.Changeset.get_attribute(submitted, :receipt_bytes) == retained.receipt_bytes do
      {:ok, retained}
    else
      Logger.warning(
        "NVR archive receipt conflict",
        binding_id: retained.archive_binding_id,
        block_key: retained.block_key,
        storage_id: retained.storage_id,
        reason: :conflicting_receipt_bytes
      )

      {:error,
       InvalidArgument.exception(
         field: :receipt_bytes,
         message: "nvr archive receipt conflicts with retained record"
       )}
    end
  end

  defp decode_json_receipt(receipt_bytes)
       when is_binary(receipt_bytes) and byte_size(receipt_bytes) in 1..@max_receipt_bytes do
    with {:ok, %Jason.OrderedObject{} = decoded} <-
           Jason.decode(receipt_bytes, objects: :ordered_objects),
         {:ok, map} when is_map(map) <- plain_json_value(decoded) do
      {:ok, map}
    else
      _ -> {:error, {:receipt_bytes, "must be a valid JSON object at most 8192 bytes"}}
    end
  end

  defp decode_json_receipt(_),
    do: {:error, {:receipt_bytes, "must be a valid JSON object at most 8192 bytes"}}

  defp plain_json_value(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      if Map.has_key?(map, key) do
        {:halt, {:error, :duplicate_key}}
      else
        case plain_json_value(value) do
          {:ok, plain} -> {:cont, {:ok, Map.put(map, key, plain)}}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp plain_json_value(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain_json_value(item) do
        {:ok, plain} -> {:cont, {:ok, [plain | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp plain_json_value(value), do: {:ok, value}

  defp parse_version(payload) do
    case Map.fetch(payload, "version") do
      :error -> {:ok, 1}
      {:ok, version} when version in [1, 2] -> {:ok, version}
      {:ok, _} -> {:error, {:receipt_bytes, "receipt version must be 1 or 2"}}
    end
  end

  defp parse_storage_id(payload) do
    case Ecto.UUID.cast(to_string(payload["storage_id"] || "")) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:receipt_bytes, "receipt storage_id must be a UUID"}}
    end
  end

  defp parse_block_key(payload) do
    raw = payload["block_key"] || payload["block_id"]

    if is_binary(raw) and Regex.match?(@hex64, raw) do
      {:ok, raw}
    else
      {:error, {:receipt_bytes, "receipt block_key must be a 64-character lowercase hex digest"}}
    end
  end

  defp parse_verified_at(%{"verified_at_ms" => ms}) when is_integer(ms) and ms >= 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} ->
        {:ok, dt.microsecond |> elem(0) |> then(&%{dt | microsecond: {&1, 6}})}

      {:error, _} ->
        {:error, {:receipt_bytes, "receipt verified_at_ms is out of range"}}
    end
  end

  defp parse_verified_at(_) do
    {:error, {:receipt_bytes, "receipt verified_at_ms must be a non-negative integer"}}
  end

  defp parse_objects(%{"objects" => objects}) when is_list(objects) and objects != [] do
    objects
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_object_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp parse_objects(_) do
    {:error, {:receipt_bytes, "receipt objects must be a non-empty list"}}
  end

  defp normalize_object_entry(entry) when is_map(entry) do
    name = entry["name"]
    key = entry["key"]
    length = entry["length"]
    sha256 = entry["sha256"]
    etag = entry["etag"]

    valid? =
      non_empty_string?(name, 64) and
        non_empty_string?(key, 512) and
        is_integer(length) and length >= 0 and
        is_binary(sha256) and Regex.match?(@hex64, sha256) and
        non_empty_string?(etag, 256)

    with true <- valid?,
         {:ok, version_id_opt} <- parse_object_version_id(entry) do
      base = %{
        "name" => name,
        "key" => key,
        "length" => length,
        "sha256" => sha256,
        "etag" => etag
      }

      {:ok, put_optional_version_id(base, version_id_opt)}
    else
      false ->
        {:error,
         {:receipt_bytes,
          "each receipt object must provide name, key, non-negative length, 64-hex sha256, and etag"}}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_object_entry(_) do
    {:error, {:receipt_bytes, "receipt object entry must be a JSON object"}}
  end

  defp parse_object_version_id(entry) do
    case Map.fetch(entry, "version_id") do
      :error ->
        {:ok, :absent}

      {:ok, nil} ->
        {:ok, {:present, nil}}

      {:ok, version_id}
      when is_binary(version_id) and byte_size(version_id) in 1..@max_version_id_bytes ->
        if Regex.match?(@printable_ascii, version_id) do
          {:ok, {:present, version_id}}
        else
          {:error,
           {:receipt_bytes,
            "receipt object version_id must be nil or a 1..1024 byte printable ASCII string"}}
        end

      {:ok, _} ->
        {:error,
         {:receipt_bytes,
          "receipt object version_id must be nil or a 1..1024 byte printable ASCII string"}}
    end
  end

  defp put_optional_version_id(base, :absent), do: base

  defp put_optional_version_id(base, {:present, version_id}),
    do: Map.put(base, "version_id", version_id)

  defp parse_optional_destination(payload) do
    dest_sha = payload["destination_sha256"]
    dest_map = payload["destination"]

    cond do
      not is_nil(dest_sha) and not (is_binary(dest_sha) and Regex.match?(@hex64, dest_sha)) ->
        {:error, {:receipt_bytes, "receipt destination_sha256 must be a 64-character hex digest"}}

      not is_nil(dest_map) and not is_map(dest_map) ->
        {:error, {:receipt_bytes, "receipt destination must be a JSON object"}}

      true ->
        {:ok, %{destination_sha256: dest_sha, destination: dest_map}}
    end
  end

  defp load_binding(binding_id, loaders) do
    loader =
      Map.get(loaders, :binding_loader, fn id ->
        Ash.get(ArchiveBinding, id, actor: @system_actor, not_found_error?: false)
      end)

    case loader.(binding_id) do
      {:ok, %ArchiveBinding{} = binding} -> {:ok, binding}
      {:ok, %{id: _, destination_sha256: _} = binding} -> {:ok, binding}
      _ -> {:error, {:archive_binding_id, "archive destination binding does not exist"}}
    end
  end

  defp verify_binding_destination(binding, %{destination_sha256: sha, destination: dest}) do
    with :ok <- check_destination_sha(binding, sha) do
      check_destination_fields(binding, dest)
    end
  end

  defp check_destination_sha(_binding, nil), do: :ok

  defp check_destination_sha(%{destination_sha256: expected}, expected), do: :ok

  defp check_destination_sha(_binding, _other) do
    {:error, {:archive_binding_id, "receipt destination_sha256 does not match archive binding"}}
  end

  defp check_destination_fields(_binding, nil), do: :ok

  defp check_destination_fields(binding, dest) when is_map(dest) do
    endpoint_matches? =
      case {dest["endpoint"], dest["host"]} do
        {nil, nil} -> true
        {ep, _} when is_binary(ep) -> ep == binding.endpoint
        {nil, host} when is_binary(host) -> "https://" <> host == binding.endpoint
        _ -> false
      end

    region_matches? = is_nil(dest["region"]) or dest["region"] == binding.region
    bucket_matches? = is_nil(dest["bucket"]) or dest["bucket"] == binding.bucket

    prefix = dest["namespace"] || dest["key_prefix"]
    prefix_matches? = is_nil(prefix) or prefix == binding.namespace

    if endpoint_matches? and region_matches? and bucket_matches? and prefix_matches? do
      :ok
    else
      {:error, {:archive_binding_id, "receipt destination fields do not match archive binding"}}
    end
  end

  defp resolve_recording_block_id(nil, storage_id, block_key, loaders) do
    block_lookup =
      Map.get(loaders, :block_lookup, fn sid, bkey ->
        RecordingBlock
        |> Ash.Query.filter(storage_id == ^sid and block_key == ^bkey)
        |> Ash.Query.select([:id])
        |> Ash.read_one(actor: @system_actor)
      end)

    case block_lookup.(storage_id, block_key) do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, nil} -> {:ok, nil}
      _ -> {:error, {:recording_block_id, "unable to resolve matching recording block"}}
    end
  end

  defp resolve_recording_block_id(explicit_id, storage_id, block_key, loaders) do
    block_loader =
      Map.get(loaders, :block_loader, fn id ->
        RecordingBlock
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.select([:id, :storage_id, :block_key])
        |> Ash.read_one(actor: @system_actor)
      end)

    case block_loader.(explicit_id) do
      {:ok, %{id: id, storage_id: ^storage_id, block_key: ^block_key}} ->
        {:ok, id}

      {:ok, %{}} ->
        {:error,
         {:recording_block_id, "recording block does not match receipt storage and block"}}

      _ ->
        {:error, {:recording_block_id, "recording block does not exist"}}
    end
  end

  defp non_empty_string?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.trim(value) == value
  end
end
