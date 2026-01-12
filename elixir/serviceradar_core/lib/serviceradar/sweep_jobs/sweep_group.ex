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

  Use `target_criteria` to define which devices to sweep using a DSL:

      %{
        "tags" => %{"has_any" => ["critical", "env=prod"]},
        "ip" => %{"in_cidr" => "10.0.0.0/8"},
        "partition" => %{"eq" => "datacenter-1"}
      }

  You can also add `static_targets` as explicit CIDRs/IPs to include.

  ## Profile Inheritance

  Optionally link to a SweepProfile for base scan settings. Override specific
  settings using `ports`, `sweep_modes`, or `overrides` map.

  ## Agent Assignment

  - `partition`: Required partition for this sweep group
  - `agent_id`: Optional specific agent (nil = any agent in partition)
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.AgentConfig.ConfigInvalidationNotifier]

  postgres do
    table "sweep_groups"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:tenant_id, :partition], name: "sweep_groups_tenant_partition_idx"
      index [:tenant_id, :agent_id],
        where: "agent_id IS NOT NULL",
        name: "sweep_groups_tenant_agent_idx"
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :partition,
        :agent_id,
        :enabled,
        :interval,
        :schedule_type,
        :cron_expression,
        :target_criteria,
        :static_targets,
        :ports,
        :sweep_modes,
        :overrides,
        :profile_id
      ]

      change ServiceRadar.Changes.AssignTenantId
      change ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor

      validate fn changeset, _context ->
        validate_target_criteria(changeset)
      end
    end

    update :update do
      require_atomic? false

      accept [
        :name,
        :description,
        :partition,
        :agent_id,
        :enabled,
        :interval,
        :schedule_type,
        :cron_expression,
        :target_criteria,
        :static_targets,
        :ports,
        :sweep_modes,
        :overrides,
        :profile_id
      ]

      change ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor

      validate fn changeset, _context ->
        validate_target_criteria(changeset)
      end
    end

    update :enable do
      change set_attribute(:enabled, true)
      change ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    update :record_execution do
      description "Record the start of an execution"
      change set_attribute(:last_run_at, &DateTime.utc_now/0)
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
                 (agent_id == ^arg(:agent_id) or is_nil(agent_id))
             )
    end

    read :for_agent_partition do
      description "Get groups for a specific agent and partition"
      argument :agent_id, :string, allow_nil?: true
      argument :partition, :string, allow_nil?: false

      filter expr(
               enabled == true and
                 partition == ^arg(:partition) and
                 (is_nil(^arg(:agent_id)) or agent_id == ^arg(:agent_id) or is_nil(agent_id))
             )
    end
  end

  defp validate_target_criteria(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :target_criteria) do
      criteria = Ash.Changeset.get_attribute(changeset, :target_criteria) || %{}

      case ServiceRadar.SweepJobs.TargetCriteria.validate(criteria) do
        :ok -> :ok
        {:error, reason} -> {:error, field: :target_criteria, message: reason}
      end
    else
      :ok
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # System actors can perform all operations within their tenant
    bypass always() do
      authorize_if expr(^actor(:role) == :system and tenant_id == ^actor(:tenant_id))
    end

    # Admins and operators can manage sweep groups
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users can read sweep groups
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this group belongs to"
    end

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
      description "Partition for this sweep group"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Specific agent ID (nil = any agent in partition)"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether this group is active"
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
    attribute :target_criteria, :map do
      allow_nil? false
      public? true
      default %{}
      description "DSL-based device targeting criteria"
    end

    attribute :static_targets, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "Explicit CIDRs/IPs to include (merged with criteria)"
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
    calculate :next_run_at, :utc_datetime, expr(
      if is_nil(last_run_at) do
        now()
      else
        # Simplified - actual calculation would parse interval
        last_run_at
      end
    )
  end

  identities do
    identity :unique_name_per_tenant, [:tenant_id, :name]
  end
end
