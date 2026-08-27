defmodule ServiceRadar.Inventory.Sync.MacVendor do
  @moduledoc """
  Derives a device vendor from the IEEE OUI registry already maintained for
  netflow enrichment.

  This is a LAST-RESORT tier. An OUI names the organisation that registered the
  NIC's address block, which is a weaker claim than a vendor a source
  authoritatively reported, and a weaker claim than what the device actually
  is: every iPhone, iPad, Mac, Apple TV and HomePod resolves to "Apple, Inc.".
  It answers "who made the network interface", not "what is this".

  ## Why this wraps the lookup instead of calling FlowEnrichment directly

  `FlowEnrichment.oui_prefix_int/1` slices the first six hex characters and
  looks them up with no check of the locally-administered bit. For flows that
  is merely noisy; for device inventory it is a false fact written to a
  long-lived record.

  A locally administered address belongs to whoever the software chose to
  imitate. Docker, VMs, overlay networks and MAC-randomising phones all use
  them, and the prefix that results can collide with a real registration.
  farm01 has exactly this case today: `F692BF75C721` is the locally
  administered form of Ubiquiti's registered `F492BF`, differing only in bit 1
  of the first octet. Devices really do derive randomised addresses from their
  own hardware address, so a prefix lookup without the bit test produces a
  confident and wrong vendor.

  So `Identity.Mac.locally_administered_mac?/1` gates every lookup here. The
  passive census (`netprobe-census`) makes that gate load-bearing rather than
  theoretical: it reports every rotating phone MAC on the segment, and on a
  live 56-device segment 14 of them were locally administered.
  """

  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Repo

  require Logger

  # Resolved vendors are tagged with this so an inference is never mistaken for
  # a vendor a source actually reported. Matches the value FlowEnrichment
  # already writes to `*_mac_vendor_source` for flows, so one string means the
  # same thing on both sides of the system.
  @source "ieee_oui"

  @source_key "mac_vendor_source"
  @prefix_key "mac_vendor_oui_prefix"
  @snapshot_key "mac_vendor_oui_snapshot_id"

  @metadata_keys [@source_key, @prefix_key, @snapshot_key]

  @doc "Metadata keys this module owns. Stripped and rewritten on every pass."
  def metadata_keys, do: @metadata_keys

  def source, do: @source

  @doc """
  Look up every usable OUI in one query.

  Batched deliberately: `SyncIngestor` works in chunks of 500 and a per-device
  query would be 500 round trips per chunk. Mirrors `Lookups.bulk_lookup_by_ip/1`.

  Returns `{lookup, snapshot_id}` where lookup maps a 24-bit prefix integer to
  an organisation. An absent or empty active snapshot yields `{%{}, nil}` and
  enrichment simply does not happen -- the OUI dataset is refreshed by a worker
  and may legitimately be missing on a fresh install.
  """
  def bulk_lookup(macs) when is_list(macs) do
    prefixes =
      macs
      |> Enum.flat_map(&prefix_for/1)
      |> Enum.uniq()

    case prefixes do
      [] -> {%{}, nil}
      _ -> query_prefixes(prefixes)
    end
  end

  @doc """
  The OUI prefix integer for a MAC, or `[]` when it must not be looked up.

  Returns a list so it composes with `flat_map`. Empty for a missing MAC, an
  unparseable MAC, or -- the case that matters -- a locally administered one.
  """
  def prefix_for(mac) do
    with normalized when is_binary(normalized) <- Mac.normalize_mac(mac),
         false <- Mac.locally_administered_mac?(normalized),
         {prefix, ""} <- normalized |> String.slice(0, 6) |> Integer.parse(16) do
      [prefix]
    else
      _ -> []
    end
  end

  @doc """
  Resolve a vendor for one MAC from a prefetched lookup.

  Returns `{organisation, prefix_hex}` or `nil`. The prefix is returned so the
  caller can record which registry entry produced the claim; without it, a
  vendor that later turns out to be wrong cannot be traced to the row that
  asserted it.
  """
  def resolve(mac, lookup) when is_map(lookup) do
    case prefix_for(mac) do
      [prefix] ->
        case Map.get(lookup, prefix) do
          org when is_binary(org) and org != "" ->
            {org, prefix |> Integer.to_string(16) |> String.pad_leading(6, "0")}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def resolve(_mac, _lookup), do: nil

  @doc """
  Record how a vendor was derived.

  Always strips first, so a device whose MAC changed -- or whose vendor is now
  supplied by a real source -- does not keep a stale attribution. This mirrors
  how classification metadata is handled, and it is why `device_writes` must
  strip these same keys in its jsonb merge: `||` is shallow and incoming keys
  win, so a key that stops being written would otherwise persist forever.
  """
  def put_provenance(metadata, {org, prefix_hex}, snapshot_id) when is_map(metadata) do
    metadata
    |> strip_provenance()
    |> Map.put(@source_key, @source)
    |> Map.put(@prefix_key, prefix_hex)
    # Normalized HERE, not just at the query, because this is the point where a
    # value enters device metadata and therefore jsonb. bulk_lookup/1 already
    # normalizes what it reads, but that only protects its own path; a raw
    # 16-byte uuid arriving from any other caller would still poison the batch
    # writer. The invariant belongs where the write happens.
    |> maybe_put(@snapshot_key, normalize_snapshot(snapshot_id))
    |> Map.put("mac_vendor", org)
  end

  def put_provenance(metadata, _resolved, _snapshot_id) when is_map(metadata),
    do: strip_provenance(metadata)

  def put_provenance(_metadata, _resolved, _snapshot_id), do: %{}

  def strip_provenance(metadata) when is_map(metadata) do
    [@metadata_keys, ["mac_vendor"]]
    |> List.flatten()
    |> Enum.reduce(metadata, &Map.delete(&2, &1))
  end

  def strip_provenance(_metadata), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp query_prefixes(prefixes) do
    sql = """
    SELECT p.oui_prefix_int, p.organization, p.snapshot_id
    FROM netflow_oui_prefixes p
    JOIN netflow_oui_dataset_snapshots s ON s.id = p.snapshot_id
    WHERE s.is_active = TRUE
      AND p.oui_prefix_int = ANY($1)
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [prefixes]) do
      {:ok, %{rows: rows}} ->
        lookup =
          Map.new(rows, fn [prefix, org, _snapshot] -> {prefix, org} end)

        snapshot_id =
          case rows do
            [[_prefix, _org, snapshot] | _] -> snapshot
            _ -> nil
          end

        {lookup, normalize_snapshot(snapshot_id)}

      {:error, error} ->
        # Never fail an ingest over enrichment. A device with no vendor is a
        # smaller problem than a batch of devices that did not land.
        Logger.warning("MAC vendor OUI lookup failed: #{inspect(error)}")
        {%{}, nil}
    end
  rescue
    error ->
      Logger.warning("MAC vendor OUI lookup raised: #{Exception.message(error)}")
      {%{}, nil}
  end

  defp normalize_snapshot(nil), do: nil

  # The failure mode is a binary that cannot be represented in JSON, not "a
  # value that is not a UUID" -- so String.valid?/1 is the test, and any
  # printable id a caller chooses keeps working.
  #
  # Postgrex returns a `uuid` column as a RAW 16-byte binary. That satisfies
  # is_binary/1, so an earlier `when is_binary(value)` clause returned it
  # untouched and the raw bytes reached device metadata. The next jsonb encode
  # of that metadata then died with
  #
  #   Jason.EncodeError: invalid byte 0xFF in <<255, 130, 164, ...>>
  #
  # which failed the WHOLE bulk device upsert -- on farm01, every sync batch,
  # with 59 devices carrying the raw value. The error surfaces in a writer that
  # never saw this module, which is what made it expensive to trace back here.
  defp normalize_snapshot(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> uuid
        :error -> nil
      end
    end
  end

  defp normalize_snapshot(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
