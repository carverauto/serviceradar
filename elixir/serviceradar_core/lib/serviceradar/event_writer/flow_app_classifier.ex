defmodule ServiceRadar.EventWriter.FlowAppClassifier do
  @moduledoc """
  Ingest-time application classification for flows, one classifier for both
  telemetry stores.

  CNPG computes `app` at query time (`FLOW_APP_EXPR` in
  `rust/srql/src/query/flows/expressions.rs`): a protocol/port baseline table,
  overridden by the best matching enabled row of
  `platform.netflow_app_classification_rules`. The warehouse read
  `dst_service_label` instead -- different case, different coverage, operator
  rules never applied (parity deviation `flow_app_is_a_different_classifier`).

  This module ports the CNPG classification exactly, so the StarRocks writer
  stamps the same label CNPG would compute at query time. Rule changes affect
  flows written after them, not history: `netflow_app_classification_rules`
  is an operator surface and its edit UI says so.

  Precedence is `FLOW_APP_EXPR`'s: rule `priority DESC`, then match
  specificity (count of non-NULL match fields) `DESC`, then `id ASC`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowAppClassificationRule

  require Logger

  @cache_key {__MODULE__, :rules}

  # The baseline table, entry for entry with FLOW_APP_EXPR. `nil` protocol
  # means the port matches on any protocol (dns, ntp).
  @baseline [
    {6, 443, "https"},
    {6, 80, "http"},
    {6, 22, "ssh"},
    {nil, 53, "dns"},
    {nil, 123, "ntp"},
    {6, 25, "smtp"},
    {6, 465, "smtp"},
    {6, 587, "smtp"},
    {6, 143, "imap"},
    {6, 993, "imap"},
    {6, 110, "pop3"},
    {6, 995, "pop3"},
    {6, 3389, "rdp"},
    {6, 5432, "postgres"},
    {6, 3306, "mysql"},
    {6, 6379, "redis"},
    {6, 27_017, "mongodb"},
    {6, 9200, "elasticsearch"}
  ]

  @doc """
  The app label for a flow: the best matching enabled rule's label, else the
  protocol/port baseline, else `"unknown"`.

  Accepts the enrichment attrs map (`protocol_num`, `dst_port`, `src_port`,
  `src_ip`, `dst_ip`, `partition`); missing or blank values are NULLs.
  """
  @spec classify(map(), [rule()]) :: String.t()
  def classify(attrs, rules) when is_map(attrs) and is_list(rules) do
    case best_rule(attrs, rules) do
      %{app_label: label} when is_binary(label) and label != "" -> label
      _ -> baseline_label(attrs) || "unknown"
    end
  end

  def classify(attrs, _rules) when is_map(attrs), do: baseline_label(attrs) || "unknown"

  @type rule :: %{
          optional(:id) => term(),
          optional(:partition) => String.t() | nil,
          optional(:protocol_num) => integer() | nil,
          optional(:dst_port) => integer() | nil,
          optional(:src_port) => integer() | nil,
          optional(:src_cidr) => String.t() | nil,
          optional(:dst_cidr) => String.t() | nil,
          optional(:app_label) => String.t() | nil,
          optional(:priority) => integer() | nil
        }

  @doc """
  The enabled classification rules, cached per batch.

  Meant to run inside `FlowEnrichment.with_provider_cache/2`, which clears the
  cache per batch so a rule edit applies to the next batch. Falls back to an
  empty list on a read failure: classification degrades to the baseline table
  rather than failing the ingest.
  """
  @spec batch_rules() :: [rule()]
  def batch_rules do
    case Process.get(@cache_key, :__serviceradar_unset__) do
      :__serviceradar_unset__ ->
        rules = load_rules()
        Process.put(@cache_key, rules)
        rules

      rules when is_list(rules) ->
        rules
    end
  end

  @doc false
  @spec clear_batch_cache() :: :ok
  def clear_batch_cache do
    Process.delete(@cache_key)
    :ok
  end

  defp load_rules do
    require Ash.Query

    actor = SystemActor.system(:flow_enrichment)

    NetflowAppClassificationRule
    |> Ash.Query.for_read(:read, actor: actor)
    |> Ash.Query.filter(enabled == true)
    |> Ash.read(authorize?: false, actor: actor)
    |> case do
      {:ok, rules} when is_list(rules) ->
        rules

      {:error, reason} ->
        Logger.warning("FlowAppClassifier: rule load failed, using baseline only",
          reason: inspect(reason)
        )

        []
    end
  rescue
    error ->
      Logger.warning("FlowAppClassifier: rule load raised, using baseline only",
        error: Exception.message(error)
      )

      []
  end

  defp best_rule(attrs, rules) do
    rules
    |> Enum.filter(&matches?(attrs, &1))
    |> Enum.max_by(&ranking/1, fn -> nil end)
  end

  defp ranking(rule) do
    specificity =
      Enum.count(
        [:protocol_num, :dst_port, :src_port, :src_cidr, :dst_cidr],
        &(not is_nil(Map.get(rule, &1)))
      )

    {Map.get(rule, :priority) || 0, specificity, -id_value(rule)}
  end

  defp id_value(rule) do
    case Map.get(rule, :id) do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
      _ -> 0
    end
  end

  defp matches?(attrs, rule) do
    field_matches?(rule, :partition, Map.get(attrs, :partition)) and
      field_matches?(rule, :protocol_num, parse_int(Map.get(attrs, :protocol_num))) and
      field_matches?(rule, :dst_port, parse_int(Map.get(attrs, :dst_port))) and
      field_matches?(rule, :src_port, parse_int(Map.get(attrs, :src_port))) and
      cidr_matches?(rule, :src_cidr, blank_to_nil(Map.get(attrs, :src_ip))) and
      cidr_matches?(rule, :dst_cidr, blank_to_nil(Map.get(attrs, :dst_ip)))
  end

  # The SQL matches `r.field IS NULL OR r.field = value`: a NULL rule field
  # is a wildcard; a non-NULL rule field must equal the flow value, and a
  # NULL flow value never equals it (`r.field = NULL` is not true).
  defp field_matches?(rule, _field, nil), do: is_nil(Map.get(rule, _field))

  defp field_matches?(rule, field, value) do
    case Map.get(rule, field) do
      nil -> true
      rule_value -> rule_value == value
    end
  end

  defp cidr_matches?(rule, _field, nil), do: is_nil(Map.get(rule, _field))

  defp cidr_matches?(rule, field, ip) do
    case Map.get(rule, field) do
      nil ->
        true

      cidr when is_binary(cidr) ->
        contains?(cidr, ip)

      _ ->
        false
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp baseline_label(attrs) do
    dst_port = parse_int(Map.get(attrs, :dst_port))
    protocol_num = parse_int(Map.get(attrs, :protocol_num))

    if is_nil(dst_port) do
      nil
    else
      Enum.find_value(@baseline, fn {rule_protocol, rule_port, label} ->
        if dst_port == rule_port and (is_nil(rule_protocol) or protocol_num == rule_protocol),
          do: label
      end)
    end
  end

  # CIDR containment in pure stdlib: both addresses parse to the same family,
  # and the IP masked by the rule's prefix equals the network address. This is
  # Postgres `inet <<= cidr` for the string form the Ash Cidr type hands us
  # ("2001:db8::/32").
  defp contains?(cidr_string, ip_string) do
    with {:ok, net, mask} <- parse_cidr(cidr_string),
         {:ok, ip} <- parse_address(ip_string),
         :same_family <- family(net, ip) do
      mask_address(ip, mask) == mask_address(net, mask)
    else
      _ -> false
    end
  end

  defp parse_cidr(value) do
    case String.split(value, "/", parts: 2) do
      [address, mask] ->
        with {:ok, ip} <- parse_address(address),
             {mask, ""} <- Integer.parse(mask) do
          {:ok, ip, mask}
        else
          _ -> :error
        end

      [address] ->
        case parse_address(address) do
          {:ok, ip} -> {:ok, ip, family_bits(ip)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_address(value) do
    case :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp family({_, _, _, _}, {_, _, _, _}), do: :same_family
  defp family({_, _, _, _, _, _, _, _}, {_, _, _, _, _, _, _, _}), do: :same_family
  defp family(_, _), do: :different

  defp family_bits({_, _, _, _}), do: 32
  defp family_bits({_, _, _, _, _, _, _, _}), do: 128

  defp mask_address({a, b, c, d}, mask) when mask >= 0 and mask <= 32 do
    bits = <<a, b, c, d>>
    <<masked::binary-size(4)>> = mask_bits(bits, mask)
    <<wa, wb, wc, wd>> = masked
    {wa, wb, wc, wd}
  end

  defp mask_address({a, b, c, d, e, f, g, h}, mask) when mask >= 0 and mask <= 128 do
    bits = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    <<masked::binary-size(16)>> = mask_bits(bits, mask)
    <<wa::16, wb::16, wc::16, wd::16, we::16, wf::16, wg::16, wh::16>> = masked
    {wa, wb, wc, wd, we, wf, wg, wh}
  end

  defp mask_bits(bits, mask) do
    total = byte_size(bits) * 8

    <<kept::bitstring-size(mask), _rest::bitstring>> = bits
    padding = total - mask
    <<kept::bitstring, 0::size(padding)>>
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
