defmodule ServiceRadar.SweepJobs.SweepGroupDeclaredTarget do
  @moduledoc """
  Declared target relation for one sweep group.

  One row per (sweep group, target) -- persisted once per GROUP, never once per
  agent, and never as part of a compiled sweep config document. Agent
  eligibility is derived at read time by `platform.device_sweep_overlap` from
  the live `sweep_groups` row (`agent_ids` / `partition`), the same way
  `SweepGroup :for_agent_partition` derives it for compilation.

  Rows are written by `ServiceRadar.SweepJobs.DeclaredTargets.refresh/1` when a
  group's targeting changes:

  - `source: "static"` -- a verbatim entry of `sweep_groups.static_targets`
  - `source: "srql"` -- an IP resolved from the group's `target_query`, with
    the device uid the compiler resolves for it

  A target that is both static and SRQL-resolved is one row carrying the device
  uid (`source: "srql"` wins), matching the dedup the previous
  compiled-config view arms performed with `max(declared_device_uid)`.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sweep_group_declared_targets"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      # The overlap view joins declared targets to sweep_groups on this key.
      index [:sweep_group_id], name: "sweep_group_declared_targets_group_idx"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:sweep_group_id, :target, :device_uid, :source, :declared_at]

      upsert? true
      upsert_identity :unique_group_target
      upsert_fields [:device_uid, :source, :declared_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    operator_action_type(:create)
    admin_action_type(:destroy)
    read_all()
  end

  attributes do
    attribute :sweep_group_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
      description "Owning sweep group"
    end

    attribute :target, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Declared IP or CIDR, verbatim from the group's targeting"
    end

    attribute :device_uid, :string do
      allow_nil? true
      public? true
      description "Device uid the SRQL target query resolved for this target, if any"
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :static
      constraints one_of: [:static, :srql]
      description "Which side of the group's targeting declared this target"
    end

    attribute :declared_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When the group's declared relation was last refreshed"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :sweep_group, ServiceRadar.SweepJobs.SweepGroup do
      allow_nil? false
      define_attribute? false
      destination_attribute :id
      source_attribute :sweep_group_id
    end
  end

  identities do
    identity :unique_group_target, [:sweep_group_id, :target]
  end
end
