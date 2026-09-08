defmodule ServiceRadar.Inventory.AdvisoryFeeds.CvePriority do
  @moduledoc """
  CVE-level priority overlay from enabled CISA KEV and VulnCheck KEV rows.

  nist-nvd2 stays the version-accurate CPE catalog (`kev` hardcoded false).
  This module builds a once-per-matcher-run `{cve_id => priority}` map and
  stamps KEV / exploit / due date / ransomware / EPSS onto match rows at emit
  time so a KEV refresh does not rewrite 360k NVD generations.

  EPSS is extracted only when it is already present on an ingested VulnCheck
  payload. CISA KEV does not carry EPSS; a dedicated EPSS index is a follow-on
  if farm01 payloads have none.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Kev
  alias ServiceRadar.Repo

  @schema "platform"
  @nvd_provider "nvd"
  @nvd_feed_key "nist-nvd2"
  @cisa_feed_key "cisa-kev"

  defstruct [
    :cve_id,
    :provider,
    :feed_key,
    kev: false,
    exploit_available: false,
    due_date: nil,
    ransomware_use: nil,
    epss_score: nil,
    title: nil,
    description: nil,
    sources: []
  ]

  @type t :: %__MODULE__{
          cve_id: String.t() | nil,
          provider: String.t() | nil,
          feed_key: String.t() | nil,
          kev: boolean(),
          exploit_available: boolean(),
          due_date: String.t() | nil,
          ransomware_use: String.t() | nil,
          epss_score: float() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          sources: [String.t()]
        }

  @doc "True when nist-nvd2 is enabled and has a current generation."
  @spec cpe_catalog_current?() :: boolean()
  def cpe_catalog_current? do
    nist_nvd2_enabled?() and nist_nvd2_current_generation?()
  end

  @doc """
  Persist operator fields onto current KEV advisories from existing `raw`.

  No re-download. Safe to call on every matcher run — rows whose metadata
  already carries `priority` are left alone.
  """
  @spec backfill_operator_fields() :: {:ok, non_neg_integer()}
  def backfill_operator_fields do
    now = DateTime.utc_now()

    updated =
      Enum.reduce(current_kev_advisories(), 0, fn advisory, acc ->
        priority = from_advisory(advisory)

        if persist_advisory(advisory, priority, now) do
          acc + 1
        else
          acc
        end
      end)

    {:ok, updated}
  end

  @doc """
  `{cve_id => priority}` union of current enabled CISA + VulnCheck KEV rows.

  Duplicate CVE ids: `kev` is true if either feed lists it; CISA wins for
  due date; both feed keys stay in `sources`.
  """
  @spec load_map() :: %{optional(String.t()) => t()}
  def load_map do
    Enum.reduce(current_kev_advisories(), %{}, fn advisory, acc ->
      priority = from_advisory(advisory)

      advisory
      |> cve_ids()
      |> Enum.reduce(acc, fn cve_id, acc2 ->
        stamped = %{priority | cve_id: cve_id}
        Map.update(acc2, cve_id, stamped, &__MODULE__.union(&1, stamped))
      end)
    end)
  end

  @doc "Extract operator fields from a raw KEV entry (or already-normalized map)."
  @spec from_entry(map()) :: t()
  def from_entry(entry) when is_map(entry) do
    fields = Kev.operator_fields(entry)

    %__MODULE__{
      cve_id: List.first(fields.cve_ids),
      kev: true,
      exploit_available: true,
      due_date: fields.due_date,
      ransomware_use: fields.ransomware_use,
      epss_score: fields.epss_score,
      title: fields.title,
      description: fields.description,
      sources: []
    }
  end

  def from_entry(_entry), do: %__MODULE__{}

  @doc "Extract from a stored advisory, preferring persisted metadata over raw."
  @spec from_advisory(map()) :: t()
  def from_advisory(advisory) when is_map(advisory) do
    metadata = map_field(advisory, :metadata)
    raw = map_field(advisory, :raw)
    from_meta = from_priority_map(priority_map(metadata))
    from_raw = from_entry(raw)
    feed_key = string_field(advisory, :feed_key)
    provider = string_field(advisory, :provider)

    %__MODULE__{
      cve_id: string_field(advisory, :cve_id) || from_meta.cve_id || from_raw.cve_id,
      provider: provider,
      feed_key: feed_key,
      kev: true,
      exploit_available: true,
      due_date: from_meta.due_date || from_raw.due_date,
      ransomware_use: from_meta.ransomware_use || from_raw.ransomware_use,
      epss_score: from_meta.epss_score || from_raw.epss_score,
      title: from_meta.title || string_field(advisory, :title) || from_raw.title,
      description:
        from_meta.description || string_field(advisory, :description) || from_raw.description,
      sources: sources_for(from_meta, feed_key)
    }
  end

  def from_advisory(_advisory), do: %__MODULE__{}

  @doc """
  Union two priority records for the same CVE.

  `kev` is true if either source listed it. CISA due date wins when both
  exist. EPSS / title / description take the first present value, preferring
  the CISA side when both are set.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = left, %__MODULE__{} = right) do
    {cisa, other} = order_cisa_first(left, right)

    %__MODULE__{
      cve_id: cisa.cve_id || other.cve_id,
      provider: cisa.provider || other.provider,
      feed_key: cisa.feed_key || other.feed_key,
      kev: cisa.kev or other.kev,
      exploit_available: cisa.exploit_available or other.exploit_available,
      due_date: cisa.due_date || other.due_date,
      ransomware_use: cisa.ransomware_use || other.ransomware_use,
      epss_score: cisa.epss_score || other.epss_score,
      title: cisa.title || other.title,
      description: cisa.description || other.description,
      sources: Enum.uniq(cisa.sources ++ other.sources)
    }
  end

  @doc """
  Overlay KEV flags onto an advisory used for match emission.

  nist-nvd2 / other non-KEV advisories pick up `kev` and `exploit_available`
  when the CVE is in the priority map. Existing KEV flags stay true.
  """
  @spec apply(map(), t() | nil) :: {map(), t() | nil}
  def apply(advisory, priority) when is_map(advisory) do
    case priority do
      %__MODULE__{kev: true} = found ->
        {%{advisory | kev: true, exploit_available: true}, found}

      _ ->
        {advisory, priority_if_already_kev(advisory)}
    end
  end

  def apply(advisory, _priority), do: {advisory, nil}

  @spec lookup(%{optional(String.t()) => t()}, String.t() | nil) :: t() | nil
  def lookup(_priority_map, nil), do: nil
  def lookup(_priority_map, ""), do: nil

  def lookup(priority_map, cve_id) when is_map(priority_map) and is_binary(cve_id) do
    Map.get(priority_map, cve_id)
  end

  def lookup(_priority_map, _cve_id), do: nil

  @spec to_metadata(t() | nil) :: map() | nil
  def to_metadata(nil), do: nil

  def to_metadata(%__MODULE__{} = priority) do
    %{
      "kev" => priority.kev,
      "exploit_available" => priority.exploit_available,
      "due_date" => priority.due_date,
      "ransomware_use" => priority.ransomware_use,
      "epss_score" => priority.epss_score,
      "title" => priority.title,
      "description" => priority.description,
      "sources" => priority.sources
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp priority_if_already_kev(%{kev: true} = advisory), do: from_advisory(advisory)
  defp priority_if_already_kev(_advisory), do: nil

  defp order_cisa_first(left, right) do
    if cisa?(left) do
      {left, right}
    else
      {right, left}
    end
  end

  defp cisa?(%__MODULE__{feed_key: @cisa_feed_key}), do: true
  defp cisa?(%__MODULE__{provider: "cisa"}), do: true
  defp cisa?(%__MODULE__{sources: sources}) when is_list(sources), do: @cisa_feed_key in sources
  defp cisa?(_priority), do: false

  defp current_kev_advisories do
    Repo.all(
      from(a in "vulnerability_advisories",
        join: f in "vulnerability_feed_definitions",
        on: f.provider == a.provider and f.feed_key == a.feed_key,
        where: a.current == true and a.kev == true and f.enabled == true,
        select: %{
          id: a.id,
          provider: a.provider,
          feed_key: a.feed_key,
          cve_id: a.cve_id,
          title: a.title,
          description: a.description,
          kev: a.kev,
          exploit_available: a.exploit_available,
          metadata: a.metadata,
          raw: a.raw
        }
      ),
      prefix: @schema
    )
  end

  defp persist_advisory(advisory, priority, now) do
    new_metadata = put_priority_metadata(map_field(advisory, :metadata), priority)

    title = preferred_title(advisory, priority)
    description = preferred_description(advisory, priority)

    changed? =
      new_metadata != map_field(advisory, :metadata) or
        title != string_field(advisory, :title) or
        description != string_field(advisory, :description)

    if changed? do
      {count, _} =
        Repo.update_all(
          from(a in "vulnerability_advisories", where: a.id == ^advisory.id),
          [
            set: [
              metadata: new_metadata,
              title: title,
              description: description,
              updated_at: now
            ]
          ],
          prefix: @schema
        )

      count > 0
    else
      false
    end
  end

  defp put_priority_metadata(metadata, priority) do
    metadata
    |> Kernel.||(%{})
    |> Map.put("priority", to_metadata(priority) || %{})
  end

  defp preferred_title(advisory, priority) do
    current = string_field(advisory, :title)
    cve_id = string_field(advisory, :cve_id)

    if is_binary(priority.title) and priority.title != "" and
         (is_nil(current) or current == cve_id) do
      priority.title
    else
      current || priority.title
    end
  end

  defp preferred_description(advisory, priority) do
    string_field(advisory, :description) || priority.description
  end

  defp cve_ids(advisory) do
    metadata_ids =
      advisory
      |> map_field(:metadata)
      |> priority_map()
      |> Map.get("cve_ids", [])
      |> List.wrap()

    raw_ids =
      advisory
      |> map_field(:raw)
      |> Map.get("_cve_ids", [])
      |> List.wrap()

    [string_field(advisory, :cve_id) | metadata_ids ++ raw_ids]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp sources_for(%__MODULE__{sources: sources}, feed_key) when is_list(sources) do
    [feed_key | sources]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp sources_for(_priority, feed_key) when is_binary(feed_key) and feed_key != "",
    do: [feed_key]

  defp sources_for(_priority, _feed_key), do: []

  defp from_priority_map(map) when map_size(map) == 0, do: %__MODULE__{}

  defp from_priority_map(map) when is_map(map) do
    %__MODULE__{
      due_date: string_value(map, "due_date"),
      ransomware_use: string_value(map, "ransomware_use"),
      epss_score: number_value(map, "epss_score"),
      title: string_value(map, "title"),
      description: string_value(map, "description"),
      sources: map |> Map.get("sources", []) |> List.wrap() |> Enum.filter(&is_binary/1),
      cve_id: map |> Map.get("cve_ids", []) |> List.wrap() |> List.first()
    }
  end

  defp from_priority_map(_map), do: %__MODULE__{}

  defp priority_map(metadata) when is_map(metadata) do
    case Map.get(metadata, "priority") || Map.get(metadata, :priority) do
      %{} = priority -> priority
      _ -> metadata
    end
  end

  defp priority_map(_metadata), do: %{}

  defp nist_nvd2_enabled? do
    Repo.one(
      from(f in "vulnerability_feed_definitions",
        where: f.provider == ^@nvd_provider and f.feed_key == ^@nvd_feed_key,
        select: f.enabled
      ),
      prefix: @schema
    ) == true
  end

  defp nist_nvd2_current_generation? do
    Repo.exists?(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@nvd_provider and a.feed_key == ^@nvd_feed_key and a.current == true
      ),
      prefix: @schema
    )
  end

  defp map_field(map, key) do
    case fetch_field(map, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp string_field(map, key) do
    case fetch_field(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_field(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp number_value(map, key) do
    case Map.get(map, key) do
      value when is_number(value) -> value / 1
      _ -> nil
    end
  end
end
