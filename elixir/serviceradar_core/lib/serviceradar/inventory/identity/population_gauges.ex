defmodule ServiceRadar.Inventory.Identity.PopulationGauges do
  @moduledoc """
  Gauges of the record populations that source id retirement, succession and seed release
  keep small (change `add-source-id-succession`, task 11.1). They are emitted as telemetry and
  exported by `ServiceRadar.Telemetry.identity_reconciliation_metrics/0`.

  `emit_inventory/0` runs after each reconciliation run (`DuplicateSweep`) and emits
  `[:serviceradar, :inventory, :identity_population]` with:

    * `retired_only_records`: live records that hold a retired source id and no
      source-authoritative or agent id. Succession merges such a record into its successor, or
      the retirement pass marks it `source_retired` (design D5).
    * `source_retired_records`: live records marked `source_retired`, which
      `ServiceRadar.Inventory.SourceRetiredExpiry` soft-deletes after the grace period.
    * `released_seed_shells`: live sweep seeds with no address, no identifier and no other
      address. A seed that releases its address is soft-deleted in the same transaction (D8),
      so this count only falls once the existing shells are cleaned up.

  The per-instance gauge, the live records of a source instance against the ids its latest
  exact collection reported, is emitted by `SourceRetirement.run/2`.

  A gauge is best-effort: a read that fails is logged and emits nothing, and never fails the run
  that took it.
  """

  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Repo

  require Logger

  @inventory_event [:serviceradar, :inventory, :identity_population]

  @archive_reason "source_absent"

  @retired_only_sql """
  SELECT count(*) FROM platform.ocsf_devices AS d
  WHERE d.deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM platform.device_identifier_archive AS a
      WHERE a.device_id = d.uid AND a.archive_reason = CAST($2 AS text)
    )
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      WHERE di.device_id = d.uid AND di.identifier_type = ANY (CAST($1 AS text[]))
    )
  """

  @source_retired_sql """
  SELECT count(*) FROM platform.ocsf_devices AS d
  WHERE d.deleted_at IS NULL AND d.source_retired_at IS NOT NULL
  """

  # The seed `DeviceWrites` soft-deletes when it releases its address (D8), after the release:
  # sweep-only, no identifier row current or archived, and no address left. The remediation
  # deletes the shells an earlier release left (`released_seed_shell/0`).
  @released_seed_shell """
  d.deleted_at IS NULL
    AND NULLIF(btrim(COALESCE(d.ip, '')), '') IS NULL
    AND EXISTS (SELECT 1 FROM unnest(d.discovery_sources) AS src WHERE lower(btrim(src)) = 'sweep')
    AND NOT EXISTS (
      SELECT 1 FROM unnest(d.discovery_sources) AS src
      WHERE btrim(src) <> '' AND lower(btrim(src)) <> 'sweep'
    )
    AND NOT EXISTS (SELECT 1 FROM platform.device_identifiers AS i WHERE i.device_id = d.uid)
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifier_archive AS a WHERE a.device_id = d.uid
    )
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_alias_states AS s
      WHERE s.device_id = d.uid AND s.alias_type IN ('ip', 'interface_ip')
        AND s.state IN ('detected', 'confirmed', 'updated')
    )
  """

  @released_seed_shells_sql """
  SELECT count(*) FROM platform.ocsf_devices AS d
  WHERE #{@released_seed_shell}
  """

  @type inventory :: %{
          retired_only_records: non_neg_integer(),
          source_retired_records: non_neg_integer(),
          released_seed_shells: non_neg_integer()
        }

  @doc "The inventory gauges, read now (see the module documentation)."
  @spec inventory() :: inventory()
  def inventory do
    marking_types = Enum.map(SourceRetirement.marking_identifier_types(), &Atom.to_string/1)

    %{
      retired_only_records: count(@retired_only_sql, [marking_types, @archive_reason]),
      source_retired_records: count(@source_retired_sql, []),
      released_seed_shells: count(@released_seed_shells_sql, [])
    }
  end

  @doc """
  Reads the inventory gauges and emits them as `[:serviceradar, :inventory,
  :identity_population]`. Never raises: a read that fails is logged and emits nothing.
  """
  @spec emit_inventory() :: :ok
  def emit_inventory do
    :telemetry.execute(@inventory_event, inventory(), %{})
  rescue
    error ->
      Logger.warning("PopulationGauges: inventory gauges not read: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("PopulationGauges: inventory gauges not read: #{inspect({kind, reason})}")
  end

  @doc false
  # The condition the record `d` meets when it is a released-seed shell, for the remediation's
  # `released-seed-shells` step (design D11, class 7), so that it deletes what the gauge counts.
  @spec released_seed_shell() :: String.t()
  def released_seed_shell, do: @released_seed_shell

  defp count(sql, params) do
    %{rows: [[count]]} = Repo.query!(sql, params)
    count
  end
end
