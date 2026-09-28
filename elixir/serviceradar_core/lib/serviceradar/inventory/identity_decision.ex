defmodule ServiceRadar.Inventory.IdentityDecision do
  @moduledoc """
  Persisted record of an identity decision DIRE made without merging.

  Every time identity reconciliation blocks, declines or overrides a merge it writes one of
  these rows, in addition to its telemetry, so an operator can review the decision later
  (requirement "Identity Decisions Are Never Silent"). The kinds:

    * `:policy_block` - `MergePolicy` refused a match set (agent-id-only, randomized-MAC-only), or
      a record linked to an allowed conflict only through randomized MACs was left out of the
      merge (`randomized_mac_link`), or a strong-identified record at an address another
      device holds agreed with it on hostname, which is not identity, and was not adopted
      (`hostname_agreement_not_identity`).
    * `:guard_block` - a `MergeEngine` guard refused an automatic merge (distinct agent
      identities, provisional topology, the per-pair cooldown).
    * `:source_block` - two records hold different identifiers from one source-authoritative
      source (`SourceAuthorityGuard`).
    * `:alias_invalidated` - an IP alias that conflicted with another device's identity was
      marked stale instead of merging the two devices.
    * `:ip_conflict` - a strong-identified record did not take an address a different device
      holds.
    * `:source_override` - a source-authoritative identifier decided a record's identity over
      conflicting MAC or address evidence.
    * `:component_block` - the scheduled duplicate sweep found devices joined only
      transitively (an ambiguous component) and did not merge them.

  Every decision naming two or more devices also opens or updates the de-duplication task for
  that device set (`ServiceRadar.Inventory.Identity.Deduplication`).

  One row per decision: kind, reason, the sorted device set and the subject (an address, when
  the decision is about one). A decision that repeats updates its row -- `occurrence_count`,
  `last_decided_at` and the latest evidence -- rather than adding a row per sync batch, so the
  table grows with the number of distinct decisions, not with ingest volume. The identifying
  columns are never rewritten.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [
    :policy_block,
    :guard_block,
    :source_block,
    :alias_invalidated,
    :ip_conflict,
    :source_override,
    :component_block
  ]

  postgres do
    table "identity_decisions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :for_device, action: :for_device, args: [:device_uid]
  end

  actions do
    defaults [:read]

    read :for_device do
      description "Identity decisions that name a device"
      argument :device_uid, :string, allow_nil?: false
      filter expr(^arg(:device_uid) in device_uids)
      prepare build(sort: [last_decided_at: :desc])
    end

    read :recent do
      description "Identity decisions, most recent first"
      prepare build(sort: [last_decided_at: :desc])
    end

    create :record do
      description "Record a decision, or count one more occurrence of an existing one"
      accept [:decision_kind, :reason, :device_uids, :subject, :source, :evidence]

      upsert? true
      upsert_identity :unique_decision_key
      upsert_fields [:source, :evidence, :last_decided_at, :updated_at]

      change ServiceRadar.Inventory.Changes.PrepareIdentityDecision
      change atomic_update(:occurrence_count, expr(occurrence_count + 1))
    end
  end

  policies do
    import ServiceRadar.Policies

    # Written only by identity reconciliation (a system actor); readable by any viewer.
    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_primary_key :id

    attribute :decision_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      description "Why the decision was made: the policy reason or guard that applied"
    end

    attribute :device_uids, {:array, :string} do
      allow_nil? false
      public? true
      description "The devices the decision is about, sorted"
    end

    attribute :subject, :string do
      public? true
      description "The address the decision is about, when it is about one"
    end

    attribute :decision_key, :string do
      allow_nil? false
      public? false
      description "Digest of kind, reason, subject and device set; one row per decision"
    end

    attribute :source, :string do
      public? true
      description "The code path that made the decision"
    end

    attribute :evidence, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :occurrence_count, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :first_decided_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_decided_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_decision_key, [:decision_key]
  end

  @doc "The decision kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The key that identifies one decision: kind, reason, subject and the sorted, de-duplicated
  device set.
  """
  @spec decision_key(atom() | String.t(), String.t(), [String.t()], String.t() | nil) ::
          String.t()
  def decision_key(kind, reason, device_uids, subject) do
    material =
      Enum.join(
        [to_string(kind), reason, subject || "", Enum.join(normalize_uids(device_uids), ",")],
        "\n"
      )

    :sha256 |> :crypto.hash(material) |> Base.encode16(case: :lower)
  end

  @doc false
  @spec normalize_uids([term()]) :: [String.t()]
  def normalize_uids(device_uids) do
    device_uids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
