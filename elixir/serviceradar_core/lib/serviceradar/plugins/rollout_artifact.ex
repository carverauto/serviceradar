defmodule ServiceRadar.Plugins.RolloutArtifact do
  @moduledoc """
  What a fleet rollout needs to know about the artifact it moves.

  `ServiceRadar.Plugins.AddonRolloutCoordinator` owns the rollout state machine:
  the rollout and target rows, batching, soak, deadlines, pause/resume/cancel,
  supersession, rollback and slot release. `ServiceRadar.Plugins.AddonRolloutEligibility`
  owns semantic-version candidate selection and agent availability. Neither knows
  which resource holds an artifact's packages, sources, per-agent desired state or
  health evidence. An implementation of this behaviour supplies exactly that.

  The coordinator relies on a small shape contract alongside the callbacks:

    * a package has `:id` and `:version`;
    * a source has `:id` and `:rollout_policy`;
    * a member (the per-agent desired-state row a target overrides) has `:id`
      and `:agent_uid`.

  Rollout and target rows record the `artifact_kind` of the implementation that
  owns them, and each family keeps its package pair and member pointer in its
  own columns. The coordinator therefore reads them through the implementation
  (`previous_package_id/1`, `candidate_package_id/1`, `member_id/1`) and writes
  them through `package_attrs/2` and `target_attrs/2`. It reads only rows whose
  kind has an implementation in `implementations/0`.

  Two implementations exist: `ServiceRadar.Plugins.AddonRolloutArtifact` for
  native add-ons and `ServiceRadar.Plugins.WasmPluginRolloutArtifact` for Wasm
  plugins. `implementation/1` picks one from a rollout or target's
  `artifact_kind`, or from the struct of a source or package.
  """

  alias Ash.Notifier.Notification
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutArtifact
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.WasmPluginRolloutArtifact

  @type actor :: term()
  @type package :: %{
          required(:id) => term(),
          required(:version) => String.t(),
          optional(atom()) => term()
        }
  @type source :: %{
          required(:id) => term(),
          required(:rollout_policy) => map() | nil,
          optional(atom()) => term()
        }
  @type member :: %{
          required(:id) => term(),
          required(:agent_uid) => String.t(),
          optional(atom()) => term()
        }
  @type evidence :: term()

  @doc "The `artifact_kind` recorded on this implementation's rollouts and targets."
  @callback artifact_kind() :: atom()

  # Sources and their stable package.

  @doc "Enabled sources that track the latest approved package and are not explicitly pinned."
  @callback managed_sources(actor()) :: {:ok, [source()]} | {:error, term()}

  @doc """
  Moves sources that were left on a manual pin nobody chose back to managed
  updates. Returns how many sources it changed.
  """
  @callback restore_managed_sources([package()], actor()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc "The `source_type` a rollout records for this source."
  @callback source_type(source()) :: atom()

  @doc "Re-reads the source a rollout was created for."
  @callback source_for_rollout(AddonRollout.t(), actor()) :: {:ok, source()} | {:error, term()}

  @doc "The id of the stable package the source currently runs."
  @callback stable_package_id(source()) :: term()

  @doc "The rollout controls the source carries, or nil for the defaults."
  @callback rollout_policy(source()) :: map() | nil

  @doc """
  Normalizes rollout controls to bounded values. A rollout snapshots the result,
  so it must be idempotent.
  """
  @callback normalize_policy(map() | nil) :: map()

  # Packages.

  @callback list_packages(actor()) :: {:ok, [package()]} | {:error, term()}
  @callback get_package(id :: term(), actor()) :: {:ok, package()} | {:error, term()}
  @callback packages_by_id([term()], actor()) :: {:ok, [package()]} | {:error, term()}

  @doc "The artifact identifier a rollout records (`addon_id`)."
  @callback artifact_id(package()) :: String.t()

  @doc "The package-pair columns of a new rollout or target row."
  @callback package_attrs(previous :: package(), candidate :: package()) :: map()

  @doc "The previous package id a rollout or target row records."
  @callback previous_package_id(AddonRollout.t() | AddonRolloutTarget.t()) :: term()

  @doc "The candidate package id a rollout or target row records."
  @callback candidate_package_id(AddonRollout.t() | AddonRolloutTarget.t()) :: term()

  # Candidate eligibility, consulted by AddonRolloutEligibility.

  @doc "Whether `candidate` is a later release of the same artifact from the same origin."
  @callback same_lineage?(candidate :: package(), current :: package()) :: boolean()

  @doc "Whether the package's approval and provenance make it a candidate at all."
  @callback trusted_approved?(package()) :: boolean()

  @doc """
  Re-reads the candidate with a share lock, inside the transaction that creates
  its rollout, and rechecks `trusted_approved?/1` on the stored row.
  `{:error, :candidate_not_eligible}` when it no longer qualifies.
  """
  @callback lock_candidate(package(), actor()) :: :ok | {:error, term()}

  @doc "Whether the package's approved capabilities stay inside the source's ceiling."
  @callback within_capability_ceiling?(package(), source() | map()) :: boolean()

  @doc "Why `agent` cannot run `package`, or nil when it can."
  @callback incompatibility(package(), agent :: map()) :: String.t() | nil

  # Target materialization.

  @doc "The members a source rolls the candidate out to."
  @callback source_members(source(), actor()) :: {:ok, [member()]} | {:error, term()}

  @doc "Ids of members whose agent has a direct source that takes precedence over this one."
  @callback overridden_members(source(), [member()], actor()) ::
              {:ok, MapSet.t()} | {:error, term()}

  @doc """
  Member-derived attributes of a new target row. They are merged over
  `package_attrs/2`, so a member may record its own previous package.
  """
  @callback target_attrs(member(), previous :: package()) :: map()

  @doc """
  The id of the member a target overrides, or nil once that member was deleted
  (its pointer is `ON DELETE SET NULL`).
  """
  @callback member_id(AddonRolloutTarget.t()) :: term() | nil

  @doc """
  Locks, `FOR UPDATE`, the rows a coordinator unit may write for the rollout:
  its owner row (a target policy or profile) and then every member assignment,
  in id order. Each unit takes them right after the rollout row and before any
  target row, the order a retraction or an owner disable also takes them in.
  """
  @callback lock_members(AddonRollout.t(), [AddonRolloutTarget.t()], actor()) ::
              :ok | {:error, term()}

  # Overrides and promotion.

  @doc """
  Puts the target's candidate on its member. The coordinator calls it inside the
  transaction that launches the target, so it returns the write's notifications
  for the coordinator to send once that transaction commits.
  `{:error, :assignment_disabled}` means the member was disabled and the target
  is canceled as `assignment_retracted`.
  """
  @callback apply_override(AddonRolloutTarget.t(), AddonRollout.t(), DateTime.t(), actor()) ::
              {:ok, [Notification.t()]} | {:error, term()}

  @doc """
  Removes the target's override, if this rollout still owns it.

  This and the other member writes below may run inside the coordinator's
  transaction, so each returns its notifications, which the coordinator sends
  once its outermost transaction commits.
  """
  @callback clear_override(AddonRolloutTarget.t(), actor()) ::
              {:ok, [Notification.t()]} | {:error, term()}

  @doc "Whether the rollout's source may absorb rolled-back members up to the policy tolerance."
  @callback tolerates_failures?(AddonRollout.t()) :: boolean()

  @doc """
  Whether one failed target rolls the whole rollout back. When false, a failed
  target pauses the rollout for an operator decision.
  """
  @callback rolls_back_on_failure?(AddonRollout.t()) :: boolean()

  @doc "Detaches a tolerated rolled-back member so it stays on its previous package."
  @callback pin_failed_member(AddonRolloutTarget.t(), actor()) ::
              {:ok, [Notification.t()]} | {:error, term()}

  @doc "Moves the rollout's source to the candidate as its stable package."
  @callback promote_source(AddonRollout.t(), actor()) ::
              {:ok, [Notification.t()]} | {:error, term()}

  # Health evidence.

  @doc "The latest evidence for each target, keyed by `evidence_key/1`."
  @callback load_evidence([AddonRolloutTarget.t()], AddonRollout.t(), actor()) ::
              %{optional(term()) => evidence()}

  @doc "The key `load_evidence/3` files a target's evidence under."
  @callback evidence_key(AddonRolloutTarget.t()) :: term()

  @callback observed_at(evidence()) :: DateTime.t() | nil

  @doc "Fresh evidence, reported since `applied_at`, that the candidate came up."
  @callback candidate_ready?(evidence() | nil, package(), applied_at :: DateTime.t() | nil) ::
              boolean()

  @doc """
  The reason code a target that `candidate_ready?/3` passed records, or nil to
  leave the target's reason code as it is.
  """
  @callback ready_reason(evidence() | nil, package(), applied_at :: DateTime.t() | nil) ::
              String.t() | nil

  @doc "Fresh evidence, reported since `applied_at`, that the candidate itself failed."
  @callback candidate_failed?(evidence() | nil, package(), applied_at :: DateTime.t() | nil) ::
              boolean()

  @doc "Fresh evidence, reported since `since`, that the previous package is running again."
  @callback recovered?(evidence() | nil, previous :: package(), since :: DateTime.t() | nil) ::
              boolean()

  @doc "Whether the evidence shows the candidate or a later version running."
  @callback converged?(evidence() | nil, package()) :: boolean()

  # Audit and telemetry.

  @callback audit_resource_type() :: String.t()
  @callback telemetry_event() :: [atom()]

  @doc "The implementation for a rollout or target, one of its sources, or one of its packages."
  @spec implementation(term()) :: module()
  def implementation(%{artifact_kind: :wasm_plugin}), do: WasmPluginRolloutArtifact
  def implementation(%{artifact_kind: :native_addon}), do: AddonRolloutArtifact
  def implementation(%PluginAssignment{}), do: WasmPluginRolloutArtifact
  def implementation(%PluginTargetPolicy{}), do: WasmPluginRolloutArtifact
  def implementation(%PluginPackage{}), do: WasmPluginRolloutArtifact
  def implementation(_addon_source_or_package), do: AddonRolloutArtifact

  @doc "Every implementation, for work that spans all rollouts."
  @spec implementations() :: [module()]
  def implementations, do: [AddonRolloutArtifact, WasmPluginRolloutArtifact]

  @doc "The artifact kinds that have an implementation."
  @spec kinds() :: [atom()]
  def kinds, do: Enum.map(implementations(), & &1.artifact_kind())

  @doc """
  Whether a guarded write matched no row because the row moved since it was read.

  Ash reports that as `Ash.Error.Changes.StaleRecord`, either bare or inside an
  `Ash.Error.Invalid` or an `Ash.Changeset`'s errors, possibly nested.
  """
  @spec stale_write?(term()) :: boolean()
  def stale_write?(%Ash.Error.Changes.StaleRecord{}), do: true
  def stale_write?(%{errors: errors}) when is_list(errors), do: stale_write?(errors)
  def stale_write?(errors) when is_list(errors), do: Enum.any?(errors, &stale_write?/1)
  def stale_write?(_error), do: false
end
