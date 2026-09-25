defmodule ServiceRadar.Inventory.DeduplicationTask do
  @moduledoc """
  A de-duplication task: a set of devices DIRE could not safely reconcile, waiting for an
  operator to decide (#4604, after ServiceNow IRE's de-duplication tasks).

  DIRE has three outcomes for a suspected duplicate: merge it automatically, keep the records
  apart because the evidence says they are different devices, or -- when it cannot tell --
  record the decision (`ServiceRadar.Inventory.IdentityDecision`) and open one of these. Every
  decision that blocks, declines or overrides a merge between two or more devices opens or
  updates the task for that device set (`ServiceRadar.Inventory.Identity.Deduplication`).

  There is exactly one task per candidate set (the sorted device uids, `candidate_key`), for
  its whole life. A repeat of any decision about the set updates the task's count, last time
  and evidence; it never opens a second task and never reopens a resolved or dismissed one.

  An operator resolves an open task by:

    * **merge** -- the devices are one; they are merged into the chosen survivor through the
      administrative merge path (`MergeEngine`, reason `manual_dedup_task`);
    * **mark distinct** -- the devices are different; a durable
      `ServiceRadar.Inventory.DistinctDeviceAssertion` is recorded for every pair, and every
      automatic merge path refuses to merge them;
    * **dismiss** -- no decision; the task stays dismissed until an operator reopens it.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Inventory.Changes.SetResolvedBy

  @statuses [:open, :merged, :distinct, :dismissed]

  postgres do
    table "identity_deduplication_tasks"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :for_device, action: :for_device, args: [:device_uid]
    define :list_open, action: :open
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :open do
      description "Open tasks, most recently decided first"
      filter expr(status == :open)
      prepare build(sort: [last_decided_at: :desc])
    end

    read :for_device do
      description "Tasks that name a device"
      argument :device_uid, :string, allow_nil?: false
      filter expr(^arg(:device_uid) in device_uids)
      prepare build(sort: [last_decided_at: :desc])
    end

    create :open_or_update do
      description "Open the task for a device set, or count one more decision about it"
      accept [:device_uids, :category, :last_decision_kind, :last_reason, :evidence]

      upsert? true
      upsert_identity :unique_candidate_key
      upsert_fields [:last_decision_kind, :last_reason, :evidence, :last_decided_at, :updated_at]

      change ServiceRadar.Inventory.Changes.PrepareDeduplicationTask
      change atomic_update(:occurrence_count, expr(occurrence_count + 1))
    end

    update :mark_merged do
      description "Record that the task's devices were merged into one survivor"
      accept [:resolution_note]
      argument :merged_into, :string, allow_nil?: false

      validate attribute_equals(:status, :open)
      change set_attribute(:merged_into, arg(:merged_into))
      change set_attribute(:status, :merged)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change SetResolvedBy
    end

    update :mark_distinct do
      description "Record that the task's devices are different devices"
      accept [:resolution_note]

      validate attribute_equals(:status, :open)
      change set_attribute(:status, :distinct)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change SetResolvedBy
    end

    update :dismiss do
      description "Close the task without a decision"
      accept [:resolution_note]

      validate attribute_equals(:status, :open)
      change set_attribute(:status, :dismissed)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change SetResolvedBy
    end

    update :reopen do
      description "Reopen a dismissed task"

      validate attribute_equals(:status, :dismissed)
      change set_attribute(:status, :open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_by, nil)
    end
  end

  policies do
    import ServiceRadar.Policies

    # Opened only by identity reconciliation (a system actor); readable by any viewer; resolved
    # by operators.
    system_bypass()
    read_viewer_plus()
    operator_action([:mark_merged, :mark_distinct, :dismiss, :reopen])
  end

  attributes do
    uuid_primary_key :id

    attribute :candidate_key, :string do
      allow_nil? false
      public? false
      description "Digest of the sorted device set; one task per set"
    end

    attribute :device_uids, {:array, :string} do
      allow_nil? false
      public? true
      description "The candidate devices, sorted"
    end

    attribute :category, :string do
      allow_nil? false
      public? true
      description "The kind of the decision that opened the task"
    end

    attribute :last_decision_kind, :string do
      allow_nil? false
      public? true
    end

    attribute :last_reason, :string do
      allow_nil? false
      public? true
      description "The reason of the most recent decision about the set"
    end

    attribute :evidence, :map do
      allow_nil? false
      default %{}
      public? true
      description "The most recent decision's evidence"
    end

    attribute :status, :atom do
      allow_nil? false
      default :open
      public? true
      constraints one_of: @statuses
    end

    attribute :occurrence_count, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :opened_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_decided_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
      public? true
    end

    attribute :resolved_by, :string do
      public? true
    end

    attribute :merged_into, :string do
      public? true
    end

    attribute :resolution_note, :string do
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_candidate_key, [:candidate_key]
  end

  @doc "The task statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The key of a device set: a digest of its sorted, de-duplicated uids."
  @spec candidate_key([String.t()]) :: String.t()
  def candidate_key(device_uids) do
    material = device_uids |> normalize_uids() |> Enum.join("\n")
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
