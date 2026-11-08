defmodule ServiceRadar.Edge.ContractRegistryEpoch do
  @moduledoc """
  One epoch of the core-derived edge-record contract registry.

  The content (`epoch`, `snapshot_sha256`, `document`, `signature`, `signing_key_id`) is
  written once, when a core node inserts the candidate, and a database trigger refuses any later
  change to it. Only `state` and its timestamps move, and `state` only moves forward: a
  `candidate` becomes `active` or is retired unactivated, an `active` epoch starts `draining`,
  and a `draining` epoch is `retired`.

  Rows are read through `ServiceRadar.Edge.ContractRegistry`, which verifies each row's
  signature before anything signs or projects under it. Only the system actor writes them.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_contract_registry_epochs"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :insert_candidate do
      description "Record a release catalog's signed registry as the candidate epoch"

      accept [
        :epoch,
        :snapshot_sha256,
        :document,
        :signature,
        :signing_key_id,
        :created_at,
        :last_matched_at
      ]

      change set_attribute(:state, :candidate)
    end

    update :activate do
      description "Make the candidate the active epoch"
      accept [:activated_at]

      validate attribute_equals(:state, :candidate)
      validate present(:activated_at)
      change set_attribute(:state, :active)
    end

    update :start_draining do
      description "Move the active epoch to draining as its successor activates"
      accept [:draining_since, :drain_until]

      validate attribute_equals(:state, :active)
      validate present([:draining_since, :drain_until])
      change set_attribute(:state, :draining)
    end

    update :retire do
      description "Retire a draining epoch once nothing signed under it can still be valid"
      accept [:retired_at]

      validate attribute_equals(:state, :draining)
      validate present(:retired_at)
      change set_attribute(:state, :retired)
    end

    update :touch_matched do
      description "Record that a live core node still runs the candidate's catalog"
      accept [:last_matched_at]

      validate attribute_equals(:state, :candidate)
      validate present(:last_matched_at)
    end

    update :retire_unactivated do
      description "Retire a candidate that never activated; it never signs anything"
      accept [:retired_at]

      validate attribute_equals(:state, :candidate)
      validate present(:retired_at)
      change set_attribute(:state, :retired)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :epoch, :integer do
      primary_key? true
      allow_nil? false
      public? true
      constraints min: 1_000_000
    end

    attribute :snapshot_sha256, :binary do
      allow_nil? false
      public? true
    end

    attribute :document, :map do
      allow_nil? false
      public? true
      description "The signed entry list (ServiceRadar.Edge.ContractRegistryEpochDocument)"
    end

    attribute :signature, :binary do
      allow_nil? false
      public? true
    end

    attribute :signing_key_id, :binary do
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      allow_nil? false
      default :candidate
      public? true
      constraints one_of: [:candidate, :active, :draining, :retired]
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :activated_at, :utc_datetime_usec, public?: true
    attribute :draining_since, :utc_datetime_usec, public?: true
    attribute :drain_until, :utc_datetime_usec, public?: true
    attribute :retired_at, :utc_datetime_usec, public?: true

    attribute :last_matched_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "The last time a live core node's catalog matched this epoch"
    end
  end
end
