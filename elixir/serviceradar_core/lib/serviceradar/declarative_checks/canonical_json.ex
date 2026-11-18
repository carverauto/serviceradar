defmodule ServiceRadar.DeclarativeChecks.CanonicalJSON do
  @moduledoc """
  Deterministic canonical JSON encoding, SHA-256 hashing, and semantic template
  fingerprinting for `schema_version: 1` declarative checks (`1.4`).

  Object keys are sorted lexicographically at every nesting level (matching the
  RFC 8785 / `ArchiveCanonicalJSON` pattern), ensuring byte-for-byte deterministic
  serialization across REST export/import, Solution Packs, and Monaco JSON sync.

  `template_fingerprint/1` hashes strictly the semantic template fields
  (`schema_version`, `slug`, `schedule`, `target_binding`, `inputs`,
  `credential_slots`, `nodes`, `edges`, `alert_policy`), excluding `ui_layout`,
  `state`, `parameter_overrides`, and database row identifiers so operators can
  tune parameters or reposition canvas nodes without breaking `managed: true`
  Solution Pack reconciliation.
  """

  @semantic_fields ~w(
    schema_version
    slug
    schedule
    target_binding
    inputs
    credential_slots
    nodes
    edges
    alert_policy
  )

  @default_schedule %{
    "interval_seconds" => 300,
    "timeout_seconds" => 30,
    "jitter_seconds" => 15
  }

  @default_target_binding %{
    "mode" => "singleton"
  }

  @default_alert_policy %{
    "emit_ocsf_transition" => true,
    "open_on_statuses" => ["down"],
    "priority" => 3,
    "threshold" => 1,
    "window_seconds" => 300,
    "cooldown_seconds" => 300,
    "renotify_seconds" => 21_600
  }

  @doc """
  Encodes `value` as compact canonical JSON with deterministically sorted object keys.
  """
  @spec encode(term()) :: String.t()
  def encode(value) do
    value
    |> ordered()
    |> Jason.encode!()
  end

  @doc """
  Encodes `value` as 2-space pretty-printed canonical JSON with sorted object keys
  and a trailing newline.
  """
  @spec encode_pretty(term()) :: String.t()
  def encode_pretty(value) do
    (value |> ordered() |> Jason.encode!(pretty: true)) <> "\n"
  end

  @doc """
  Computes the lowercase 64-character SHA-256 hex digest of `encode(value)`.
  """
  @spec sha256(term()) :: String.t()
  def sha256(value) do
    :sha256
    |> :crypto.hash(encode(value))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Extracts the normalized semantic template map used to compute `template_fingerprint`.
  """
  @spec semantic_template_map(map() | struct()) :: map()
  def semantic_template_map(doc_or_struct) when is_map(doc_or_struct) do
    raw = plain_map(doc_or_struct)

    %{
      "schema_version" => fetch_field(raw, "schema_version", 1),
      "slug" => to_string(fetch_field(raw, "slug", "")),
      "schedule" => normalize_schedule(fetch_field(raw, "schedule", %{})),
      "target_binding" =>
        normalize_target_binding(fetch_field(raw, "target_binding", @default_target_binding)),
      "inputs" => normalize_list(fetch_field(raw, "inputs", [])),
      "credential_slots" => normalize_list(fetch_field(raw, "credential_slots", [])),
      "nodes" => normalize_list(fetch_field(raw, "nodes", [])),
      "edges" => normalize_list(fetch_field(raw, "edges", [])),
      "alert_policy" => normalize_alert_policy(fetch_field(raw, "alert_policy", %{}))
    }
  end

  @doc """
  Computes the deterministic lowercase SHA-256 `template_fingerprint` over the
  semantic template fields (`#{Enum.join(@semantic_fields, ", ")}`).
  """
  @spec template_fingerprint(map() | struct()) :: String.t()
  def template_fingerprint(doc_or_struct) when is_map(doc_or_struct) do
    doc_or_struct
    |> semantic_template_map()
    |> sha256()
  end

  @doc "Alias for `template_fingerprint/1`."
  @spec compute_template_fingerprint(map() | struct()) :: String.t()
  def compute_template_fingerprint(doc_or_struct) when is_map(doc_or_struct) do
    template_fingerprint(doc_or_struct)
  end

  @doc """
  Converts a `DeclarativeCheck` struct or validated document map into a portable,
  secret-free `schema_version: 1` canonical export map, omitting database UUIDs,
  credential binding IDs, and runtime timestamps.
  """
  @spec to_canonical_export_map(map() | struct()) :: map()
  def to_canonical_export_map(doc_or_struct) when is_map(doc_or_struct) do
    raw = plain_map(doc_or_struct)
    semantic = semantic_template_map(raw)
    fingerprint = fetch_field(raw, "template_fingerprint", nil) || sha256(semantic)

    state_val =
      case fetch_field(raw, "state", "draft") do
        atom when is_atom(atom) -> Atom.to_string(atom)
        str when is_binary(str) -> str
        _ -> "draft"
      end

    base = %{
      "schema_version" => 1,
      "slug" => semantic["slug"],
      "name" => to_string(fetch_field(raw, "name", semantic["slug"])),
      "description" => fetch_field(raw, "description", nil),
      "state" => state_val,
      "pack_id" => fetch_field(raw, "pack_id", nil),
      "pack_version" => fetch_field(raw, "pack_version", nil),
      "managed" => fetch_field(raw, "managed", false) == true,
      "template_fingerprint" => fingerprint,
      "parameter_overrides" => normalize_map(fetch_field(raw, "parameter_overrides", %{})),
      "schedule" => semantic["schedule"],
      "target_binding" => semantic["target_binding"],
      "inputs" => semantic["inputs"],
      "credential_slots" => semantic["credential_slots"],
      "nodes" => semantic["nodes"],
      "edges" => semantic["edges"],
      "alert_policy" => semantic["alert_policy"]
    }

    case fetch_field(raw, "ui_layout", nil) do
      layout when is_map(layout) and map_size(layout) > 0 ->
        Map.put(base, "ui_layout", normalize_map(layout))

      _ ->
        base
    end
  end

  @doc """
  Normalizes schedule fields with canonical defaults.
  """
  @spec normalize_schedule(term()) :: map()
  def normalize_schedule(schedule) when is_map(schedule) do
    Map.merge(@default_schedule, normalize_map(schedule))
  end

  def normalize_schedule(_), do: @default_schedule

  @doc """
  Normalizes target_binding fields with canonical singleton default when omitted or empty.
  """
  @spec normalize_target_binding(term()) :: map()
  def normalize_target_binding(binding) when is_map(binding) do
    case normalize_map(binding) do
      empty when map_size(empty) == 0 -> @default_target_binding
      normalized -> normalized
    end
  end

  def normalize_target_binding(_), do: @default_target_binding

  @doc """
  Normalizes alert_policy fields with canonical defaults.
  """
  @spec normalize_alert_policy(term()) :: map()
  def normalize_alert_policy(policy) when is_map(policy) do
    Map.merge(@default_alert_policy, normalize_map(policy))
  end

  def normalize_alert_policy(_), do: @default_alert_policy

  @doc false
  def ordered(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def ordered(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  def ordered(%Date{} = date), do: Date.to_iso8601(date)

  def ordered(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__lateral_join_source__, :calculations, :aggregates])
    |> ordered()
  end

  def ordered(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {stringify_key(key), ordered(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  def ordered(value) when is_boolean(value) or is_nil(value), do: value
  def ordered(value) when is_atom(value), do: Atom.to_string(value)
  def ordered(value), do: value

  defp plain_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp plain_map(map) when is_map(map), do: map

  defp normalize_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), normalize_term(v)} end)
  end

  defp normalize_map(_), do: %{}

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &normalize_term/1)
  defp normalize_list(_), do: []

  defp normalize_term(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_term(map) when is_map(map) and not is_struct(map), do: normalize_map(map)
  defp normalize_term(list) when is_list(list), do: Enum.map(list, &normalize_term/1)
  defp normalize_term(val) when is_boolean(val) or is_nil(val), do: val
  defp normalize_term(val) when is_atom(val), do: Atom.to_string(val)
  defp normalize_term(val), do: val

  defp fetch_field(map, str_key, default) do
    atom_key =
      try do
        String.to_existing_atom(str_key)
      rescue
        ArgumentError -> nil
      end

    cond do
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> default
    end
  end

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)
end
