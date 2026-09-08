defmodule ServiceRadar.SweepJobs.SweepGroup do
  @moduledoc """
  User-configured sweep groups with custom schedules and device targeting.

  SweepGroup is the primary organizational unit for network sweeps. Each group
  defines what to scan, when to scan, and which agent should perform the scan.

  ## Scheduling

  Groups have independent schedules. You can use either:
  - Interval-based: `interval: "15m"`, `interval: "2h"`, `interval: "1d"`
  - Cron-based: `schedule_type: :cron`, `cron_expression: "0 */6 * * *"`

  ## Device Targeting

  Use `target_query` to define which devices to sweep using SRQL:

      "in:devices tags:critical ip:10.0.0.0/8 partition:datacenter-1"

  You can also add `static_targets` as explicit CIDRs/IPs to include.

  ## Profile Inheritance

  Optionally link to a SweepProfile for base scan settings. Override specific
  settings using `ports`, `sweep_modes`, or `overrides` map.

  ## Agent Assignment

  - `partition`: Device-lookup partition for ingest. Partition-wide groups are
    compiled onto agents that live in this same partition.
  - `agent_ids`: Canonical scanner assignment. An empty list means every agent
    in `partition`; a non-empty list means exactly the selected scanners. A
    selected agent still receives and runs the group when it lives in another
    partition, which is how isolation scans work: a scanner on a blocked subnet
    probes devices in a different device partition.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.SweepJobs.Changes.NormalizeAgentAssignment
  alias ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor
  alias ServiceRadar.SweepJobs.Changes.ValidateSrqlQuery
  alias ServiceRadar.SweepJobs.Validations.AgentAssignment

  @group_fields [
    :name,
    :description,
    :partition,
    :agent_id,
    :agent_ids,
    :enabled,
    :interval,
    :schedule_type,
    :cron_expression,
    :target_query,
    :static_targets,
    :ports,
    :sweep_modes,
    :overrides,
    :profile_id,
    :emit_availability_events
  ]

  postgres do
    table "sweep_groups"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:partition], name: "sweep_groups_partition_idx"

      index [:agent_id],
        where: "agent_id IS NOT NULL",
        name: "sweep_groups_agent_idx"

      index [:agent_ids], name: "sweep_groups_agent_ids_gin_idx", using: "gin"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @group_fields

      change NormalizeAgentAssignment
      validate AgentAssignment
      change ScheduleSweepMonitor
      change ValidateSrqlQuery
    end

    update :update do
      require_atomic? false

      accept @group_fields

      change NormalizeAgentAssignment
      validate AgentAssignment
      change ScheduleSweepMonitor
      change ValidateSrqlQuery
    end

    update :enable do
      change set_attribute(:enabled, true)
      change ScheduleSweepMonitor
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    update :record_execution do
      description "Record the start of an execution"
      change set_attribute(:last_run_at, &DateTime.utc_now/0)
    end

    update :run_now do
      description "Trigger an on-demand sweep run"
      accept []
      change ServiceRadar.SweepJobs.Changes.DispatchSweepRun
    end

    update :add_targets do
      description "Add IP addresses/CIDRs to static_targets"
      require_atomic? false

      argument :targets, {:array, :string} do
        allow_nil? false
        description "List of IP addresses or CIDRs to add"
      end

      change fn changeset, _context ->
        new_targets = Ash.Changeset.get_argument(changeset, :targets) || []
        existing_targets = changeset.data.static_targets || []

        # Merge and deduplicate
        merged_targets =
          (existing_targets ++ new_targets)
          |> Enum.uniq()
          |> Enum.sort()

        Ash.Changeset.change_attribute(changeset, :static_targets, merged_targets)
      end
    end

    update :remove_targets do
      description "Remove IP addresses/CIDRs from static_targets"
      require_atomic? false

      argument :targets, {:array, :string} do
        allow_nil? false
        description "List of IP addresses or CIDRs to remove"
      end

      change fn changeset, _context ->
        targets_to_remove = Ash.Changeset.get_argument(changeset, :targets) || []
        existing_targets = changeset.data.static_targets || []

        filtered_targets = Enum.reject(existing_targets, &(&1 in targets_to_remove))

        Ash.Changeset.change_attribute(changeset, :static_targets, filtered_targets)
      end
    end

    read :enabled_groups do
      description "List enabled sweep groups"
      filter expr(enabled == true)
    end

    read :by_partition do
      argument :partition, :string, allow_nil?: false
      filter expr(partition == ^arg(:partition) and enabled == true)
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false

      filter expr(
               enabled == true and
                 (agent_ids == [] or
                    (not is_nil(^arg(:agent_id)) and ^arg(:agent_id) != "" and
                       ^arg(:agent_id) in agent_ids))
             )
    end

    read :for_agent_partition do
      description """
      Groups this agent should run.

      Includes (1) groups whose fixed subset contains this agent, including isolation scans
      whose device partition differs from the agent's, and (2) partition-wide
      groups whose partition matches the agent's.
      """

      argument :agent_id, :string, allow_nil?: true
      argument :partition, :string, allow_nil?: false

      filter expr(
               enabled == true and
                 ((not is_nil(^arg(:agent_id)) and ^arg(:agent_id) != "" and
                     fragment("? @> ?", agent_ids, [^arg(:agent_id)])) or
                    (agent_ids == [] and partition == ^arg(:partition)))
             )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
    read_all()
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable group name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of the group's purpose"
    end

    attribute :partition, :string do
      allow_nil? false
      public? true
      default "default"
      description "Device-lookup partition; partition-wide groups also compile onto agents here"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Compatibility mirror of the first selected scanner agent ID"
    end

    attribute :agent_ids, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Canonical scanner agent IDs (empty = all agents in the partition)"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this group is active"
    end

    attribute :emit_availability_events, :boolean do
      allow_nil? false
      public? true
      default false
      description "Emit device.unavailable / device.available logs when sweep flips is_available"
    end

    # Schedule configuration
    attribute :interval, :string do
      allow_nil? false
      public? true
      default "1h"
      description "Sweep interval (e.g., '15m', '2h', '1d')"
    end

    attribute :schedule_type, :atom do
      allow_nil? false
      public? true
      default :interval
      constraints one_of: [:interval, :cron]
      description "Schedule type: interval or cron"
    end

    attribute :cron_expression, :string do
      allow_nil? true
      public? true
      description "Cron expression for cron-based scheduling"
    end

    # Device targeting
    attribute :target_query, :string do
      allow_nil? true
      public? true
      description "SRQL query for device targeting (e.g., 'in:devices tags.role:database')"
    end

    attribute :static_targets, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Explicit CIDRs/IPs to include (merged with SRQL targets)"
    end

    # Scan configuration (overrides profile)
    attribute :ports, {:array, :integer} do
      allow_nil? true
      public? true
      description "Override profile ports"
    end

    attribute :sweep_modes, {:array, :string} do
      allow_nil? true
      public? true
      description "Override profile modes"
    end

    attribute :overrides, :map do
      allow_nil? false
      public? true
      default %{}
      description "Other setting overrides"
    end

    # Tracking
    attribute :last_run_at, :utc_datetime do
      allow_nil? true
      public? true
      description "When this group was last executed"
    end

    attribute :profile_id, :uuid do
      allow_nil? true
      public? true
      description "Optional base profile"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :profile, ServiceRadar.SweepJobs.SweepProfile do
      allow_nil? true
      define_attribute? false
      destination_attribute :id
      source_attribute :profile_id
    end

    has_many :executions, ServiceRadar.SweepJobs.SweepGroupExecution do
      destination_attribute :sweep_group_id
    end
  end

  calculations do
    calculate :next_run_at,
              :utc_datetime,
              expr(
                if is_nil(last_run_at) do
                  now()
                else
                  # Simplified - actual calculation would parse interval
                  last_run_at
                end
              )
  end

  aggregates do
    # Deleting a group discards its executions and their per-host results. The
    # delete confirmation quotes this count so an operator sees the size of what
    # they are discarding before they agree to it, rather than after.
    count :execution_count, :executions
  end

  identities do
    identity :unique_name, [:name]
  end
end
