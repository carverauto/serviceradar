defmodule ServiceRadar.Inventory.SourceFacts do
  @moduledoc """
  Platform inventory facts: parse, normalize, and decide promotion.

  Persistence and events live in `ServiceRadar.Inventory.SourceFacts.Reconciler`.
  """

  @keys ~w(switch_port_attachment vlan_uid)
  @forbidden_manifest_keys ~w(
    fact_authority authority precedence winner winners wins
    canonical_priority authoritative
  )

  @type fact :: %{
          optional(:raw) => String.t() | nil,
          fact_key: String.t(),
          value: map(),
          compare_hash: String.t()
        }

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec key?(term()) :: boolean()
  def key?(key) when is_binary(key), do: key in @keys
  def key?(_key), do: false

  @spec forbidden_manifest_keys() :: [String.t()]
  def forbidden_manifest_keys, do: @forbidden_manifest_keys

  @spec extract(map()) :: [fact()]
  def extract(update) when is_map(update) do
    metadata = map_field(update, :metadata)
    explicit = parse_explicit_facts(map_field(update, :facts), metadata)
    armis = parse_armis_metadata(metadata)

    Enum.uniq_by(explicit ++ armis, & &1.fact_key)
  end

  def extract(_update), do: []

  @spec parse_armis_metadata(map()) :: [fact()]
  def parse_armis_metadata(metadata) when is_map(metadata) do
    []
    |> maybe_put_fact(parse_armis_attachment(metadata))
    |> maybe_put_fact(parse_armis_vlan(metadata))
  end

  def parse_armis_metadata(_metadata), do: []

  @spec parse_explicit_facts(term(), map()) :: [fact()]
  def parse_explicit_facts(facts, metadata \\ %{})

  def parse_explicit_facts(facts, metadata) when is_map(facts) do
    fallback = map_field(metadata, :canonical_facts)

    facts
    |> Map.merge(if(is_map(fallback), do: fallback, else: %{}))
    |> Enum.flat_map(fn {key, value} ->
      case normalize_key(key) do
        fact_key when fact_key in @keys ->
          maybe_put_fact([], parse_explicit_value(fact_key, value))

        _other ->
          []
      end
    end)
  end

  def parse_explicit_facts(_facts, _metadata), do: []

  @spec source_instance(map()) :: String.t()
  def source_instance(update) when is_map(update) do
    metadata = map_field(update, :metadata)

    first_present([
      string_field(update, :source_instance),
      string_field(metadata, :source_instance),
      string_field(metadata, :integration_source_id),
      string_field(update, :agent_id)
    ]) || "default"
  end

  def source_instance(_update), do: "default"

  @spec source(map()) :: String.t()
  def source(update) when is_map(update) do
    first_present([
      string_field(update, :source),
      string_field(map_field(update, :metadata), :plugin_discovery_source)
    ]) || "unknown"
  end

  def source(_update), do: "unknown"

  @spec decide(list(), list(), map() | nil) ::
          {:promote, map(), map() | nil}
          | {:hold, map() | nil}
          | {:config_conflict, map()}
          | :noop
  def decide(facts, authorities, _current) when is_list(facts) and is_list(authorities) do
    present = Enum.filter(facts, &present?/1)

    case grouped(present) do
      [] ->
        :noop

      [{_hash, winners}] ->
        {:promote, pick_agreed_winner(winners, authorities), nil}

      groups ->
        decide_conflict(groups, authorities)
    end
  end

  def decide(_facts, _authorities, _current), do: :noop

  defp decide_conflict(groups, authorities) do
    disagreement = disagreement_payload(groups)
    matching = matching_authorities(groups, authorities)
    unique_sources = matching |> Enum.map(& &1.source) |> Enum.uniq()

    case unique_sources do
      [source] ->
        winner = first_fact_for_source(groups, source)
        {:promote, winner, disagreement}

      [] ->
        {:hold, disagreement}

      _multiple ->
        {:config_conflict, Map.put(disagreement, :configuration_conflict, true)}
    end
  end

  defp matching_authorities(groups, authorities) do
    facts = Enum.flat_map(groups, fn {_hash, facts} -> facts end)

    authorities
    |> Enum.filter(&(&1[:enabled] != false))
    |> Enum.filter(fn authority ->
      Enum.any?(facts, &authority_matches?(authority, &1))
    end)
    |> Enum.sort_by(&{&1[:rank] || 100, &1[:inserted_at] || 0})
  end

  defp authority_matches?(authority, fact) do
    authority_source = to_string(authority[:source] || "")
    authority_instance = authority[:source_instance]

    authority_source == fact.source and
      (authority_instance in [nil, ""] or authority_instance == fact.source_instance)
  end

  defp pick_agreed_winner(winners, authorities) do
    ranked =
      winners
      |> Enum.map(fn fact ->
        rank =
          authorities
          |> Enum.filter(&authority_matches?(&1, fact))
          |> Enum.map(&(&1[:rank] || 100))
          |> Enum.min(fn -> 100 end)

        {rank, fact}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    case ranked do
      [{_rank, fact} | _] -> fact
      [] -> hd(winners)
    end
  end

  defp first_fact_for_source(groups, source) do
    groups
    |> Enum.flat_map(fn {_hash, facts} -> facts end)
    |> Enum.find(&(&1.source == source))
  end

  defp grouped(facts) do
    facts
    |> Enum.group_by(& &1.compare_hash)
    |> Enum.sort_by(fn {hash, _facts} -> hash end)
  end

  defp disagreement_payload(groups) do
    values =
      groups
      |> Enum.map(fn {_hash, facts} ->
        Enum.map(facts, fn fact ->
          %{
            "source" => fact.source,
            "source_instance" => fact.source_instance,
            "value" => fact.value,
            "compare_hash" => fact.compare_hash
          }
        end)
      end)
      |> List.flatten()

    hashes = groups |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{
      values: %{"sources" => values},
      compare_signature: Enum.join(hashes, "|"),
      configuration_conflict: false
    }
  end

  defp present?(fact), do: Map.get(fact, :present, true)

  defp parse_armis_attachment(metadata) do
    raw = first_present([string_field(metadata, :armis_access_switch)])

    case split_hostname_port(raw) do
      {hostname, port} ->
        build_attachment_fact(%{
          "switch_hostname" => hostname,
          "port" => port,
          "raw" => raw
        })

      :error ->
        nil
    end
  end

  defp parse_armis_vlan(metadata) do
    case vlan_id_from_armis(metadata) do
      nil -> nil
      vlan_id -> build_vlan_fact(vlan_id)
    end
  end

  defp parse_explicit_value("switch_port_attachment", value) when is_map(value) do
    hostname =
      first_present([string_field(value, :switch_hostname), string_field(value, :hostname)])

    port = first_present([string_field(value, :port), string_field(value, :if_name)])

    if hostname && port do
      build_attachment_fact(%{
        "switch_hostname" => hostname,
        "port" => port,
        "switch_device_uid" => string_field(value, :switch_device_uid),
        "if_alias" => string_field(value, :if_alias),
        "vlan_id" => vlan_id_string(Map.get(value, "vlan_id") || Map.get(value, :vlan_id)),
        "vlan_name" => string_field(value, :vlan_name),
        "raw" => string_field(value, :raw) || hostname <> ":" <> port
      })
    end
  end

  defp parse_explicit_value("switch_port_attachment", value) when is_binary(value) do
    case split_hostname_port(value) do
      {hostname, port} ->
        build_attachment_fact(%{
          "switch_hostname" => hostname,
          "port" => port,
          "raw" => value
        })

      :error ->
        nil
    end
  end

  defp parse_explicit_value("vlan_uid", value) do
    case vlan_id_string(value) do
      nil -> nil
      vlan_id -> build_vlan_fact(vlan_id)
    end
  end

  defp parse_explicit_value(_key, _value), do: nil

  defp build_attachment_fact(value) do
    hostname = normalize_hostname(value["switch_hostname"])
    port = normalize_port(value["port"])
    vlan_id = value["vlan_id"]

    compare = %{
      "switch_hostname" => hostname,
      "port" => port,
      "vlan_id" => vlan_id
    }

    %{
      fact_key: "switch_port_attachment",
      value: Map.reject(value, fn {_k, v} -> is_nil(v) or v == "" end),
      compare_hash: hash(compare),
      raw: value["raw"]
    }
  end

  defp build_vlan_fact(vlan_id) do
    %{
      fact_key: "vlan_uid",
      value: %{"vlan_uid" => vlan_id},
      compare_hash: hash(%{"vlan_uid" => vlan_id}),
      raw: vlan_id
    }
  end

  defp split_hostname_port(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.split(trimmed, ":", parts: :infinity) do
      parts when length(parts) >= 2 ->
        port = List.last(parts)
        hostname = parts |> Enum.drop(-1) |> Enum.join(":")

        if hostname != "" and port != "" do
          {String.trim(hostname), String.trim(port)}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp split_hostname_port(_value), do: :error

  defp vlan_id_from_armis(metadata) do
    first_present([
      vlan_id_string(Map.get(metadata, "armis_vlan") || Map.get(metadata, :armis_vlan)),
      vlan_id_from_list(Map.get(metadata, "armis_vlans") || Map.get(metadata, :armis_vlans))
    ])
  end

  defp vlan_id_from_list(value) when is_list(value) do
    value
    |> Enum.map(&vlan_id_string/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp vlan_id_from_list(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, "[") ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> vlan_id_from_list(decoded)
          _ -> vlan_id_string(trimmed)
        end

      true ->
        vlan_id_string(trimmed)
    end
  end

  defp vlan_id_from_list(_value), do: nil

  defp vlan_id_string(value) when is_integer(value) and value > 0, do: Integer.to_string(value)

  defp vlan_id_string(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.trim_leading("#")

    cond do
      trimmed == "" ->
        nil

      Regex.match?(~r/^\d{1,4}$/, trimmed) ->
        trimmed

      true ->
        nil
    end
  end

  defp vlan_id_string(_value), do: nil

  defp normalize_hostname(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_hostname(_value), do: ""

  defp normalize_port(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_port(_value), do: ""

  defp hash(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_fact(facts, nil), do: facts
  defp maybe_put_fact(facts, fact), do: facts ++ [fact]

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: ""

  defp map_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || %{}
  end

  defp map_field(_map, _key), do: %{}

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value when is_atom(value) ->
        Atom.to_string(value)

      _other ->
        nil
    end
  end

  defp string_field(_map, _key), do: nil

  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))
end
