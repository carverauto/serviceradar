defmodule ServiceRadarAgentGateway.EdgeRecordTrust do
  @moduledoc """
  The gateway's LOCAL edge-record trust snapshot (unify-sweep-results-proto task 3.2).

  Every capability an edge record carries -- the production grant, an optional source
  authorization, and an optional delivery capability on the wrapper -- is verified against this
  snapshot, in process, with no core, ERTS or database round trip per frame. The snapshot is the
  gateway's peer of Go's `edgerecord.CapabilityTrust` plus `AuthorizationPolicy`:

    * `:trust_policy_epoch` -- the single pinned, nonzero policy generation every key in one
      frame decision resolves at, so a revocation cannot mix snapshots inside one frame;
    * `:keys` -- verifying Ed25519 keys by EXACT `{issuer_id, issuer_key_id}`, each with the set of
      capability PURPOSES it may issue and its lifecycle status. A key that exists but is not
      authorized for the requested purpose resolves `:key_invalid`: only this resolver knows which
      roles a key may issue, so a scheduler key cannot mint a production grant. A key id the
      snapshot does not hold resolves `:key_unavailable`: a key the issuer rotated to after this
      snapshot was loaded looks exactly like an unknown one until the snapshot is replaced;
    * `:fences` -- the active producer authority generation by
      `{network_scope_id, producer_assignment_id, run_shard}`;
    * `:scopes` -- the network scopes each agent is assigned, by the certificate `component_id`
      the edge identity resolver authenticates;
    * `:clock_tolerance_nano` -- bounded skew applied to every current-at-now window check.

  ## Fence semantics

  A fence entry names a producer's ACTIVE authority generation. A record whose epoch equals its
  entry is current; below it is stale; above it is a generation this gateway has not learned yet.
  A producer with NO entry is unavailable: this snapshot does not know its active generation, and
  a missing entry never reads as current. Future and unavailable are both retryable and never
  authorized. An absent SNAPSHOT is unavailable, and nothing authorizes.

  ## Network scope authority

  A certificate subject names no network scope, so an agent's scope authority is derived from the
  principal it authenticates (`ServiceRadarAgentGateway.ComponentIdentityResolver`) and this
  snapshot's `:scopes` binding for that principal (`with_network_scopes/2`). A record is admitted
  only into a scope that binding lists AND its signed production grant names, so neither the grant
  nor the binding authorizes a scope alone. A principal with no binding is unbound: nothing
  authorizes its records, and they are withheld as retryable. A binding that excludes the record's
  scope is a permanent scope conflict.

  ## Loading

  `load_configured/0` reads the `:serviceradar_agent_gateway, :edge_record_trust` `:file` (set from
  `AGENT_GATEWAY_EDGE_RECORD_TRUST_FILE`). These are verifying PUBLIC keys for ServiceRadar talking
  to itself, not device or integration credentials. The file is JSON; byte fields are standard
  base64:

      {
        "trust_policy_epoch": 1,
        "clock_tolerance_nano": 0,
        "keys": [
          {"issuer_id": "<b64>", "issuer_key_id": "<b64>", "public_key": "<b64, 32 bytes>",
           "purposes": ["production", "source", "delivery"], "status": "valid"}
        ],
        "fences": [
          {"network_scope_id": "<b64>", "producer_assignment_id": "<b64>", "run_shard": 0,
           "authority_epoch": 2}
        ],
        "scopes": [
          {"agent_id": "<certificate component id>", "network_scope_ids": ["<b64, 16-byte UUID>"]}
        ]
      }

  `"status"` is `"valid"` (includes a normally rotated key retained for history) or
  `"historically_revoked"` (compromise-revoked: the signature still verifies, but trust is
  deliberately withdrawn and the record can only reach security quarantine).
  """

  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.PublicationIdentity

  require Logger

  @pt_key __MODULE__
  @purposes %{"production" => :production, "source" => :source, "delivery" => :delivery}
  @statuses %{"valid" => :valid, "historically_revoked" => :historically_revoked}
  # Go's MaxClockToleranceNano: five minutes.
  @max_clock_tolerance_nano 5 * 60 * 1_000_000_000
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @u32_max 0xFFFF_FFFF

  @type purpose :: :production | :source | :delivery
  @type key_status :: :valid | :historically_revoked
  @type fence_key :: {binary(), binary(), non_neg_integer()}

  @type snapshot :: %{
          trust_policy_epoch: pos_integer(),
          clock_tolerance_nano: non_neg_integer(),
          keys: %{{binary(), binary()} => %{public_key: binary(), purposes: MapSet.t(), status: key_status()}},
          fences: %{fence_key() => non_neg_integer()},
          scopes: %{String.t() => MapSet.t()}
        }

  @doc "The installed snapshot, or `{:error, :trust_unavailable}` when none is loaded."
  @spec snapshot() :: {:ok, snapshot()} | {:error, :trust_unavailable}
  def snapshot do
    case :persistent_term.get(@pt_key, nil) do
      nil -> {:error, :trust_unavailable}
      snapshot -> {:ok, snapshot}
    end
  end

  @doc "Whether a snapshot is installed."
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _}, snapshot())

  @doc """
  Validates and installs a snapshot given in the decoded JSON shape (string keys, base64 bytes).
  An invalid document installs nothing and leaves any previous snapshot in place.
  """
  @spec install(map()) :: :ok | {:error, term()}
  def install(document) do
    with {:ok, snapshot} <- new(document) do
      :persistent_term.put(@pt_key, snapshot)
      :ok
    end
  end

  @doc "Validates a decoded trust document into a snapshot WITHOUT installing it."
  @spec new(map()) :: {:ok, snapshot()} | {:error, term()}
  def new(document), do: parse(document)

  @doc "Removes the installed snapshot, so nothing authorizes."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@pt_key)
    :ok
  end

  @doc """
  Loads the configured trust file, if any. A missing configuration leaves the snapshot
  unavailable, which keeps `edge-records:v1` from becoming ready. A configured but unreadable or
  invalid file is logged and also leaves it unavailable: failing closed at readiness rather than
  crashing a gateway whose other lanes do not depend on it.
  """
  @spec load_configured() :: :ok | {:error, term()}
  def load_configured do
    case :serviceradar_agent_gateway |> Application.get_env(:edge_record_trust, []) |> Keyword.get(:file) do
      path when is_binary(path) and path != "" -> load_file(path)
      _ -> {:error, :not_configured}
    end
  end

  @doc "Reads, validates and installs the trust file at `path`."
  @spec load_file(Path.t()) :: :ok | {:error, term()}
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, document} <- Jason.decode(body),
         :ok <- install(document) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("edge record trust file #{path} was not installed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Resolves the verifying key for `{issuer_id, issuer_key_id}` in the role `purpose`.

  `{:ok, public_key, status}` for a known key authorized for that role; `{:error, :key_invalid}`
  for a known key not authorized to issue `purpose`; `{:error, :key_unavailable}` for a key id this
  snapshot does not hold.
  """
  @spec resolve_key(snapshot(), binary(), binary(), purpose()) ::
          {:ok, binary(), key_status()} | {:error, :key_invalid | :key_unavailable}
  def resolve_key(%{keys: keys}, issuer_id, issuer_key_id, purpose) do
    case Map.get(keys, {issuer_id, issuer_key_id}) do
      %{public_key: public_key, purposes: purposes, status: status} ->
        if MapSet.member?(purposes, purpose), do: {:ok, public_key, status}, else: {:error, :key_invalid}

      nil ->
        {:error, :key_unavailable}
    end
  end

  @doc """
  Classifies a producer authority epoch against the active fence for `fence_key`: `:current`,
  `:stale` (below the active generation), `:future` (a generation not yet learned locally) or
  `:unavailable` (no fence entry, so the active generation is unknown here).
  """
  @spec fence_relation(snapshot(), fence_key(), non_neg_integer()) :: :current | :stale | :future | :unavailable
  def fence_relation(%{fences: fences}, fence_key, epoch) do
    case Map.fetch(fences, fence_key) do
      :error -> :unavailable
      {:ok, active} when epoch < active -> :stale
      {:ok, active} when epoch > active -> :future
      {:ok, _active} -> :current
    end
  end

  @doc """
  `identity` with `:network_scope_ids` set to the network scopes this snapshot binds its
  authenticated `:component_id` to, or to `nil` when the snapshot has no binding for that principal.
  """
  @spec with_network_scopes(snapshot(), map()) :: map()
  def with_network_scopes(%{scopes: scopes}, identity) do
    Map.put(identity, :network_scope_ids, Map.get(scopes, Map.get(identity, :component_id)))
  end

  # --- parsing ---------------------------------------------------------------------------------

  defp parse(%{"trust_policy_epoch" => epoch} = document) when is_integer(epoch) and epoch > 0 and epoch <= @u64_max do
    tolerance = Map.get(document, "clock_tolerance_nano", 0)

    with :ok <-
           check(is_integer(tolerance) and tolerance >= 0 and tolerance <= @max_clock_tolerance_nano, :clock_tolerance),
         {:ok, keys} <- parse_list(Map.get(document, "keys", []), &parse_key/1),
         {:ok, fences} <- parse_list(Map.get(document, "fences", []), &parse_fence/1),
         {:ok, scopes} <- parse_list(Map.get(document, "scopes", []), &parse_scope/1),
         :ok <- check(keys != [], :no_keys),
         :ok <- check(unique?(Enum.map(keys, &elem(&1, 0))), :duplicate_key),
         :ok <- check(unique?(Enum.map(fences, &elem(&1, 0))), :duplicate_fence),
         :ok <- check(unique?(Enum.map(scopes, &elem(&1, 0))), :duplicate_scope_binding) do
      {:ok,
       %{
         trust_policy_epoch: epoch,
         clock_tolerance_nano: tolerance,
         keys: Map.new(keys),
         fences: Map.new(fences),
         scopes: Map.new(scopes)
       }}
    end
  end

  defp parse(_document), do: {:error, :trust_policy_epoch}

  defp parse_list(items, parser) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parser.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_list(_items, _parser), do: {:error, :not_a_list}

  defp parse_key(%{} = key) do
    with {:ok, issuer_id} <- nonempty_bytes(key["issuer_id"], :issuer_id),
         {:ok, issuer_key_id} <- nonempty_bytes(key["issuer_key_id"], :issuer_key_id),
         {:ok, public_key} <- nonempty_bytes(key["public_key"], :public_key),
         :ok <- check(byte_size(public_key) == 32, :public_key),
         {:ok, purposes} <- parse_purposes(key["purposes"]),
         {:ok, status} <- lookup(@statuses, Map.get(key, "status", "valid"), :status) do
      {:ok, {{issuer_id, issuer_key_id}, %{public_key: public_key, purposes: purposes, status: status}}}
    end
  end

  defp parse_key(_key), do: {:error, :key}

  defp parse_purposes(purposes) when is_list(purposes) and purposes != [] do
    with {:ok, parsed} <- parse_list(purposes, &lookup(@purposes, &1, :purpose)) do
      {:ok, MapSet.new(parsed)}
    end
  end

  defp parse_purposes(_purposes), do: {:error, :purposes}

  defp parse_fence(%{} = fence) do
    shard = fence["run_shard"]
    epoch = fence["authority_epoch"]

    with {:ok, scope} <- nonempty_bytes(fence["network_scope_id"], :network_scope_id),
         {:ok, assignment} <- nonempty_bytes(fence["producer_assignment_id"], :producer_assignment_id),
         :ok <- check(is_integer(shard) and shard >= 0 and shard <= @u32_max, :run_shard),
         :ok <- check(is_integer(epoch) and epoch >= 0 and epoch <= @u64_max, :authority_epoch) do
      {:ok, {{scope, assignment, shard}, epoch}}
    end
  end

  defp parse_fence(_fence), do: {:error, :fence}

  defp parse_scope(%{"network_scope_ids" => [_ | _] = ids} = binding) do
    agent_id = binding["agent_id"]

    with :ok <- check(PublicationIdentity.valid_authenticated_principal?(agent_id), :agent_id),
         {:ok, network_scope_ids} <- parse_list(ids, &network_scope_id/1),
         :ok <- check(unique?(network_scope_ids), :duplicate_network_scope) do
      {:ok, {agent_id, MapSet.new(network_scope_ids)}}
    end
  end

  defp parse_scope(_binding), do: {:error, :scope_binding}

  defp network_scope_id(value) do
    with {:ok, bytes} <- nonempty_bytes(value, :network_scope_id),
         :ok <- check(PlanValidate.canonical_uuid?(bytes), :network_scope_id) do
      {:ok, bytes}
    end
  end

  defp nonempty_bytes(value, field) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} when bytes != "" -> {:ok, bytes}
      _ -> {:error, field}
    end
  end

  defp nonempty_bytes(_value, field), do: {:error, field}

  defp lookup(table, value, field) do
    case Map.fetch(table, value) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, field}
    end
  end

  defp unique?(values), do: length(values) == length(Enum.uniq(values))

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
