defmodule ServiceRadar.Edge.NetperfPermitSigning do
  @moduledoc """
  Canonical binary framing, Ed25519 signing, and verification for `NetperfPermitV1`.

  Signed using `ServiceRadar.Edge.IssuerKey` (`issuer_id = "serviceradar-core"`).
  Go Hub Responders verify permits against the `keys` list delivered in
  `AgentConfigResponse.edge_record_trust_document` (`RecordTrust.agent_snapshot/2`)
  and enforce the plain monotonic `uint64` fencing contract
  `permit.authority_epoch >= responder.min_authority_epoch`.

  ## Canonical Preimage Layout

  All integers are big-endian unsigned (`u64`) or signed (`i64`) with explicit
  range checks; all strings and byte slices are length-prefixed with `u64` byte
  size. Lists (`allowed_protocols`, `allowed_directions`) are normalized to
  lowercase, deduplicated, sorted lexicographically, and framed as
  `u64(count) || item_0 || ...`.

      bytes("serviceradar.netperf.permit.v1")
      u64(permit_version)           # 1
      bytes(permit_id)
      bytes(issuer_id)
      bytes(issuer_key_id)          # 16 bytes
      bytes(algorithm)              # "ed25519"
      bytes(sender_agent_id)
      bytes(responder_agent_id)
      bytes(partition_id)
      bytes(policy_id)
      u64(max_bandwidth_bps)
      u64(max_duration_sec)
      u64(max_parallel)
      u64(len(allowed_protocols))  || bytes(...)...
      u64(len(allowed_directions)) || bytes(...)...
      u64(authority_epoch)
      i64(issued_at_unix)
      i64(expires_at_unix)
  """

  alias Netperf.V1.NetperfDirection
  alias Netperf.V1.NetperfPermitV1
  alias Netperf.V1.NetperfProtocol
  alias ServiceRadar.Edge.IssuerKey

  @domain "serviceradar.netperf.permit.v1"
  @permit_id_domain "serviceradar.netperf.permit_id.v1"
  @permit_version 1
  @algorithm "ed25519"
  @seconds_per_day 86_400
  @scheduled_lead_sec 300
  @scheduled_window_days 8

  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @i64_max 0x7FFF_FFFF_FFFF_FFFF

  @doc """
  Computes the canonical binary preimage for a `NetperfPermitV1` struct or map.
  """
  @spec preimage(NetperfPermitV1.t() | map()) :: binary()
  def preimage(permit) when is_map(permit) do
    protocols = normalize_protocols(get_field(permit, :allowed_protocols, []))
    directions = normalize_directions(get_field(permit, :allowed_directions, []))

    IO.iodata_to_binary([
      bytes(@domain),
      u64(get_field(permit, :permit_version, @permit_version) || @permit_version),
      bytes(get_field(permit, :permit_id, "")),
      bytes(get_field(permit, :issuer_id, "")),
      bytes(get_field(permit, :issuer_key_id, <<>>)),
      bytes(get_field(permit, :algorithm, @algorithm) || @algorithm),
      bytes(get_field(permit, :sender_agent_id, "")),
      bytes(get_field(permit, :responder_agent_id, "")),
      bytes(get_field(permit, :partition_id, "")),
      bytes(get_field(permit, :policy_id, "")),
      u64(get_field(permit, :max_bandwidth_bps, 0) || 0),
      u64(get_field(permit, :max_duration_sec, 0) || 0),
      u64(get_field(permit, :max_parallel, 0) || 0),
      list_bytes(protocols),
      list_bytes(directions),
      u64(get_field(permit, :authority_epoch, 0) || 0),
      i64(get_field(permit, :issued_at_unix, 0) || 0),
      i64(get_field(permit, :expires_at_unix, 0) || 0)
    ])
  end

  @doc """
  Builds and signs a UTC-day-aligned scheduled `NetperfPermitV1` for a
  `(policy, profile, responder, sender_agent_id, partition_id)` tuple.

  Because `issued_at_unix`, `expires_at_unix`, and `permit_id` are aligned to the
  current UTC day and RFC 8032 Ed25519 signing is deterministic, repeated compiles
  on the same UTC day produce byte-identical permits.
  """
  @spec sign_scheduled(map(), map(), map(), String.t(), String.t(), keyword()) ::
          {:ok, NetperfPermitV1.t()} | {:error, term()}
  def sign_scheduled(policy, profile, responder, sender_agent_id, partition_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    now_unix = DateTime.to_unix(now, :second)
    day_bucket = div(now_unix, @seconds_per_day) * @seconds_per_day
    issued_at_unix = day_bucket - @scheduled_lead_sec
    expires_at_unix = day_bucket + @scheduled_window_days * @seconds_per_day

    policy_epoch = normalize_authority_epoch(Map.get(policy, :authority_epoch, 1))
    responder_epoch = normalize_authority_epoch(Map.get(responder, :authority_epoch, 1))
    authority_epoch = responder_epoch

    policy_id = to_string(Map.fetch!(policy, :id))
    responder_agent_id = to_string(Map.fetch!(responder, :agent_uid))

    permit_id =
      deterministic_permit_id(
        policy_id,
        responder_agent_id,
        sender_agent_id,
        {policy_epoch, responder_epoch},
        day_bucket
      )

    claims = %{
      permit_id: permit_id,
      partition_id: partition_id,
      sender_agent_id: sender_agent_id,
      responder_agent_id: responder_agent_id,
      policy_id: policy_id,
      max_bandwidth_bps: Map.fetch!(profile, :bandwidth_bps),
      max_duration_sec: Map.fetch!(profile, :duration_sec),
      max_parallel: Map.fetch!(profile, :parallel),
      allowed_protocols: [Map.fetch!(profile, :protocol)],
      allowed_directions: [Map.fetch!(profile, :direction)],
      issued_at_unix: issued_at_unix,
      expires_at_unix: expires_at_unix,
      authority_epoch: authority_epoch
    }

    sign_claims(claims, opts)
  end

  @doc """
  Builds and signs a short-lived one-shot `NetperfPermitV1` for on-demand `netperf.run`.
  """
  @spec sign_on_demand(map(), keyword()) :: {:ok, NetperfPermitV1.t()} | {:error, term()}
  def sign_on_demand(params, opts \\ []) when is_map(params) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    now_unix = DateTime.to_unix(now, :second)
    duration_sec = Map.fetch!(params, :duration_sec)
    ttl_sec = Map.get(params, :ttl_seconds, max(duration_sec + 120, 300))
    command_id = Map.get(params, :command_id) || Ecto.UUID.generate()

    claims = %{
      permit_id: Map.get(params, :permit_id) || Ecto.UUID.generate(),
      partition_id: Map.fetch!(params, :partition_id),
      sender_agent_id: Map.fetch!(params, :sender_agent_id),
      responder_agent_id: Map.fetch!(params, :responder_agent_id),
      policy_id: "on_demand:" <> to_string(command_id),
      max_bandwidth_bps: Map.fetch!(params, :bandwidth_bps),
      max_duration_sec: duration_sec,
      max_parallel: Map.fetch!(params, :parallel),
      allowed_protocols: [Map.fetch!(params, :protocol)],
      allowed_directions: [Map.fetch!(params, :direction)],
      issued_at_unix: now_unix - 60,
      expires_at_unix: now_unix + ttl_sec,
      authority_epoch: normalize_authority_epoch(Map.get(params, :authority_epoch, 1))
    }

    sign_claims(claims, opts)
  end

  @doc """
  Signs a claim map with `opts[:issuer_key]` or `IssuerKey.configured/0`.
  """
  @spec sign_claims(map(), keyword()) :: {:ok, NetperfPermitV1.t()} | {:error, term()}
  def sign_claims(claims, opts \\ []) when is_map(claims) do
    with {:ok, key} <- resolve_issuer_key(opts) do
      protocols = normalize_protocols(Map.get(claims, :allowed_protocols, []))
      directions = normalize_directions(Map.get(claims, :allowed_directions, []))

      unsigned = %NetperfPermitV1{
        permit_version: @permit_version,
        permit_id: Map.fetch!(claims, :permit_id),
        partition_id: Map.fetch!(claims, :partition_id),
        sender_agent_id: Map.fetch!(claims, :sender_agent_id),
        responder_agent_id: Map.fetch!(claims, :responder_agent_id),
        policy_id: Map.fetch!(claims, :policy_id),
        max_bandwidth_bps: Map.fetch!(claims, :max_bandwidth_bps),
        max_duration_sec: Map.fetch!(claims, :max_duration_sec),
        max_parallel: Map.fetch!(claims, :max_parallel),
        allowed_protocols: Enum.map(protocols, &proto_protocol_enum/1),
        allowed_directions: Enum.map(directions, &proto_direction_enum/1),
        issued_at_unix: Map.fetch!(claims, :issued_at_unix),
        expires_at_unix: Map.fetch!(claims, :expires_at_unix),
        authority_epoch: Map.get(claims, :authority_epoch, 1) || 1,
        issuer_id: key.issuer_id,
        issuer_key_id: key.key_id,
        algorithm: @algorithm,
        signature: <<>>
      }

      signature = IssuerKey.sign_detached(preimage(unsigned), key)
      {:ok, %{unsigned | signature: signature}}
    end
  end

  @doc """
  Verifies structural invariants and Ed25519 signature of a `NetperfPermitV1`.
  """
  @spec verify(NetperfPermitV1.t() | term(), binary()) :: boolean()
  def verify(%NetperfPermitV1{} = permit, public_key)
      when is_binary(public_key) and byte_size(public_key) == 32 do
    with :ok <- validate_structure(permit),
         true <- is_binary(permit.signature) and byte_size(permit.signature) == 64 do
      :crypto.verify(:eddsa, :none, preimage(permit), permit.signature, [public_key, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  def verify(_permit, _public_key), do: false

  @doc """
  Encodes a `NetperfPermitV1` into a JSON/cache-safe string-keyed map.
  """
  @spec to_compiled_map(NetperfPermitV1.t()) :: map()
  def to_compiled_map(%NetperfPermitV1{} = permit) do
    %{
      "permit_version" => permit.permit_version,
      "permit_id" => permit.permit_id,
      "partition_id" => permit.partition_id,
      "sender_agent_id" => permit.sender_agent_id,
      "responder_agent_id" => permit.responder_agent_id,
      "policy_id" => permit.policy_id,
      "max_bandwidth_bps" => permit.max_bandwidth_bps,
      "max_duration_sec" => permit.max_duration_sec,
      "max_parallel" => permit.max_parallel,
      "allowed_protocols" => normalize_protocols(permit.allowed_protocols),
      "allowed_directions" => normalize_directions(permit.allowed_directions),
      "issued_at_unix" => permit.issued_at_unix,
      "expires_at_unix" => permit.expires_at_unix,
      "authority_epoch" => permit.authority_epoch,
      "issuer_id" => permit.issuer_id,
      "issuer_key_id_b64" => Base.encode64(permit.issuer_key_id || <<>>),
      "algorithm" => permit.algorithm,
      "signature_b64" => Base.encode64(permit.signature || <<>>)
    }
  end

  @doc """
  Reconstructs a `NetperfPermitV1` proto struct from a JSON/cache-safe compiled map.
  """
  @spec to_proto(map() | NetperfPermitV1.t() | nil) :: NetperfPermitV1.t() | nil
  def to_proto(nil), do: nil
  def to_proto(%NetperfPermitV1{} = permit), do: permit

  def to_proto(permit) when is_map(permit) do
    %NetperfPermitV1{
      permit_version: Map.get(permit, "permit_version", @permit_version) || @permit_version,
      permit_id: Map.get(permit, "permit_id", "") || "",
      partition_id: Map.get(permit, "partition_id", "") || "",
      sender_agent_id: Map.get(permit, "sender_agent_id", "") || "",
      responder_agent_id: Map.get(permit, "responder_agent_id", "") || "",
      policy_id: Map.get(permit, "policy_id", "") || "",
      max_bandwidth_bps: Map.get(permit, "max_bandwidth_bps", 0) || 0,
      max_duration_sec: Map.get(permit, "max_duration_sec", 0) || 0,
      max_parallel: Map.get(permit, "max_parallel", 0) || 0,
      allowed_protocols:
        permit
        |> Map.get("allowed_protocols", [])
        |> normalize_protocols()
        |> Enum.map(&proto_protocol_enum/1),
      allowed_directions:
        permit
        |> Map.get("allowed_directions", [])
        |> normalize_directions()
        |> Enum.map(&proto_direction_enum/1),
      issued_at_unix: Map.get(permit, "issued_at_unix", 0) || 0,
      expires_at_unix: Map.get(permit, "expires_at_unix", 0) || 0,
      authority_epoch: Map.get(permit, "authority_epoch", 0) || 0,
      issuer_id: Map.get(permit, "issuer_id", "") || "",
      issuer_key_id: decode_b64(Map.get(permit, "issuer_key_id_b64")),
      algorithm: Map.get(permit, "algorithm", @algorithm) || @algorithm,
      signature: decode_b64(Map.get(permit, "signature_b64"))
    }
  end

  defp validate_structure(%NetperfPermitV1{} = permit) do
    cond do
      Map.get(permit, :__unknown_fields__, []) != [] ->
        {:error, :unknown_fields}

      permit.permit_version != @permit_version ->
        {:error, :version}

      permit.algorithm != @algorithm ->
        {:error, :algorithm}

      permit.issuer_id == "" or byte_size(permit.issuer_key_id || <<>>) == 0 ->
        {:error, :issuer}

      not (i64?(permit.issued_at_unix) and i64?(permit.expires_at_unix)) ->
        {:error, :window}

      permit.expires_at_unix <= permit.issued_at_unix ->
        {:error, :window}

      permit.sender_agent_id == "" or permit.responder_agent_id == "" ->
        {:error, :agents}

      permit.sender_agent_id == permit.responder_agent_id ->
        {:error, :self_target}

      true ->
        :ok
    end
  end

  defp resolve_issuer_key(opts) do
    case Keyword.get(opts, :issuer_key) do
      %IssuerKey{} = key -> {:ok, key}
      nil -> IssuerKey.configured()
      other -> {:error, {:invalid_issuer_key, other}}
    end
  end

  defp normalize_authority_epoch(value) when is_integer(value) and value >= 1, do: value
  defp normalize_authority_epoch(_value), do: 1

  defp deterministic_permit_id(
         policy_id,
         responder_agent_id,
         sender_agent_id,
         {policy_epoch, responder_epoch},
         day_bucket
       ) do
    digest =
      :crypto.hash(:sha256, [
        @permit_id_domain,
        ":",
        policy_id,
        ":",
        responder_agent_id,
        ":",
        sender_agent_id,
        ":",
        Integer.to_string(policy_epoch),
        ":",
        Integer.to_string(responder_epoch),
        ":",
        Integer.to_string(day_bucket)
      ])

    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6), _::binary>> = digest

    Enum.join(
      [
        Base.encode16(a, case: :lower),
        Base.encode16(b, case: :lower),
        Base.encode16(c, case: :lower),
        Base.encode16(d, case: :lower),
        Base.encode16(e, case: :lower)
      ],
      "-"
    )
  end

  @doc false
  @spec proto_protocol_enum(String.t() | atom()) :: NetperfProtocol.t()
  def proto_protocol_enum("tcp"), do: :NETPERF_PROTOCOL_TCP
  def proto_protocol_enum(:tcp), do: :NETPERF_PROTOCOL_TCP
  def proto_protocol_enum("udp"), do: :NETPERF_PROTOCOL_UDP
  def proto_protocol_enum(:udp), do: :NETPERF_PROTOCOL_UDP
  def proto_protocol_enum(_), do: :NETPERF_PROTOCOL_UNSPECIFIED

  @doc false
  @spec proto_direction_enum(String.t() | atom()) :: NetperfDirection.t()
  def proto_direction_enum("upload"), do: :NETPERF_DIRECTION_UPLOAD
  def proto_direction_enum(:upload), do: :NETPERF_DIRECTION_UPLOAD
  def proto_direction_enum("download"), do: :NETPERF_DIRECTION_DOWNLOAD
  def proto_direction_enum(:download), do: :NETPERF_DIRECTION_DOWNLOAD
  def proto_direction_enum("bidirectional"), do: :NETPERF_DIRECTION_BIDIRECTIONAL
  def proto_direction_enum(:bidirectional), do: :NETPERF_DIRECTION_BIDIRECTIONAL
  def proto_direction_enum(_), do: :NETPERF_DIRECTION_UNSPECIFIED

  defp normalize_protocols(values) when is_list(values) do
    values
    |> Enum.map(&protocol_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_protocols(_), do: []

  defp protocol_name(:NETPERF_PROTOCOL_TCP), do: "tcp"
  defp protocol_name(:NETPERF_PROTOCOL_UDP), do: "udp"
  defp protocol_name(1), do: "tcp"
  defp protocol_name(2), do: "udp"
  defp protocol_name(:tcp), do: "tcp"
  defp protocol_name(:udp), do: "udp"

  defp protocol_name(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "tcp" -> "tcp"
      "udp" -> "udp"
      _ -> nil
    end
  end

  defp protocol_name(_), do: nil

  defp normalize_directions(values) when is_list(values) do
    values
    |> Enum.map(&direction_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_directions(_), do: []

  defp direction_name(:NETPERF_DIRECTION_UPLOAD), do: "upload"
  defp direction_name(:NETPERF_DIRECTION_DOWNLOAD), do: "download"
  defp direction_name(:NETPERF_DIRECTION_BIDIRECTIONAL), do: "bidirectional"
  defp direction_name(1), do: "upload"
  defp direction_name(2), do: "download"
  defp direction_name(3), do: "bidirectional"
  defp direction_name(:upload), do: "upload"
  defp direction_name(:download), do: "download"
  defp direction_name(:bidirectional), do: "bidirectional"

  defp direction_name(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "upload" -> "upload"
      "download" -> "download"
      "bidirectional" -> "bidirectional"
      _ -> nil
    end
  end

  defp direction_name(_), do: nil

  defp decode_b64(value) when is_binary(value) and value != "" do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> <<>>
    end
  end

  defp decode_b64(_), do: <<>>

  defp get_field(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp list_bytes(items) do
    [u64(length(items)) | Enum.map(items, &bytes/1)]
  end

  defp u64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp i64(v) when is_integer(v) and v >= @i64_min and v <= @i64_max, do: <<v::big-signed-64>>
  defp i64?(v), do: is_integer(v) and v >= @i64_min and v <= @i64_max
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
end
