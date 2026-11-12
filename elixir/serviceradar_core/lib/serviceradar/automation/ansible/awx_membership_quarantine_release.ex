defmodule ServiceRadar.Automation.Ansible.AwxMembershipQuarantineRelease do
  @moduledoc """
  Human release of one quarantined AWX host membership: the only exit from
  quarantine.

  The request carries the membership ID, its AWX source tuple, and the source
  generation, fingerprint and link-evidence digest shown to the reviewer.
  Authority comes from `AwxMembershipReviewer`, exactly as for approval.

  Under the controller's observation lock, so that synchronization cannot
  interleave, the service re-reads the membership, re-evaluates its source tuple
  against current device inventory with the reconciler's own lookup, and then:

    * one matching device: the membership becomes `proposed` with fresh
      evidence and still needs a normal approval;
    * no matching device: it becomes `unlinked`;
    * several matching devices: it is refused with
      `{:membership_link_ambiguous, device_uids}` and left quarantined.

  It never produces `approved`. The membership update and its
  `AwxMembershipQuarantineReleaseRecord` commit together.
  """

  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxInventoryObservationFence
  alias ServiceRadar.Automation.Ansible.AwxMembershipQuarantineReleaseRecord
  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Automation.Ansible.AwxMembershipReviewer, as: Reviewer
  alias ServiceRadar.Repo

  @request_keys ~w(
    membership_id
    controller_id
    inventory_id
    awx_host_id
    source_generation
    source_fingerprint
    link_evidence_digest
  )

  @doc """
  Releases one exact quarantined membership as the currently logged-in human.

  A `ServiceRadarWebNG.Accounts.Scope`-shaped map or the user actor itself may
  be passed as the second argument. Returns the released membership.
  """
  @spec release(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def release(request, scope_or_actor, opts \\ [])

  def release(request, scope_or_actor, opts) when is_map(request) and is_list(opts) do
    dependencies = dependencies(opts)

    with {:ok, request} <-
           Reviewer.normalize_request(request, @request_keys, :invalid_release_request),
         {:ok, actor} <- Reviewer.authorize(scope_or_actor, dependencies) do
      dependencies.transaction.(fn -> release_locked(request, actor, dependencies) end)
    end
  rescue
    _ -> {:error, :membership_release_denied}
  end

  def release(_request, _scope_or_actor, _opts), do: {:error, :invalid_release_request}

  defp release_locked(request, actor, dependencies) do
    tuple = {request.controller_id, request.inventory_id, request.awx_host_id}

    with :ok <- dependencies.lock_controller.(request.controller_id),
         {:ok, membership} <- load_membership(dependencies, request.membership_id),
         :ok <- Reviewer.exact_source_identity(membership, request),
         :ok <- Reviewer.exact_source_evidence(membership, request),
         :ok <- current_quarantine(membership),
         {:ok, matches} <- dependencies.current_matches.(tuple, Reviewer.store_actor()),
         {:ok, outcome} <- outcome(tuple, matches),
         released_at = dependencies.now.(),
         true <- is_struct(released_at, DateTime) || {:error, :release_clock_invalid},
         {:ok, released} <-
           dependencies.release_membership.(
             membership,
             release_attributes(request, membership, outcome),
             actor
           ),
         {:ok, _record} <-
           dependencies.record_release.(
             record_attributes(membership, outcome, actor, released_at)
           ) do
      {:ok, released}
    end
  end

  defp dependencies(opts) do
    defaults = %{
      transaction: &default_transaction/1,
      lock_controller: &AwxInventoryObservationFence.lock_controller/1,
      load_membership: &default_load_membership/1,
      current_matches: &AwxMembershipReconciler.current_matches/2,
      release_membership: &default_release_membership/3,
      record_release: &default_record_release/1,
      now: &DateTime.utc_now/0
    }

    defaults
    |> Map.merge(Keyword.get(opts, :dependencies, %{}))
    |> Reviewer.dependencies()
  end

  defp load_membership(dependencies, membership_id) do
    case dependencies.load_membership.(membership_id) do
      {:ok, membership} when not is_nil(membership) -> {:ok, membership}
      _ -> {:error, :membership_not_found}
    end
  end

  defp current_quarantine(membership) do
    cond do
      Reviewer.field(membership, :link_disposition) != :quarantined ->
        {:error, :membership_not_quarantined}

      Reviewer.field(membership, :current) != true or
          not is_nil(Reviewer.field(membership, :expired_at)) ->
        {:error, :membership_not_current}

      true ->
        :ok
    end
  end

  defp outcome(tuple, [device_uid]) do
    {:ok,
     %{
       disposition: :proposed,
       canonical_device_uid: device_uid,
       evidence: AwxMembershipReconciler.source_tuple_evidence(tuple, [device_uid])
     }}
  end

  defp outcome(tuple, []) do
    {:ok,
     %{
       disposition: :unlinked,
       canonical_device_uid: nil,
       evidence: AwxMembershipReconciler.source_tuple_evidence(tuple, [])
     }}
  end

  defp outcome(_tuple, matches), do: {:error, {:membership_link_ambiguous, matches}}

  defp release_attributes(request, membership, outcome) do
    %{
      controller_id: request.controller_id,
      inventory_id: request.inventory_id,
      awx_host_id: request.awx_host_id,
      source_generation: request.source_generation,
      source_fingerprint: request.source_fingerprint,
      expected_link_evidence: Reviewer.field(membership, :link_evidence),
      released_link_disposition: outcome.disposition,
      canonical_device_uid: outcome.canonical_device_uid,
      released_link_evidence: outcome.evidence
    }
  end

  defp record_attributes(membership, outcome, actor, released_at) do
    %{
      membership_id: Reviewer.field(membership, :id),
      controller_id: Reviewer.field(membership, :controller_id),
      inventory_id: Reviewer.field(membership, :inventory_id),
      awx_host_id: Reviewer.field(membership, :awx_host_id),
      released_by_principal_id: actor.id,
      released_at: released_at,
      prior_quarantine_reason: Reviewer.field(membership, :quarantine_reason),
      prior_quarantined_at: Reviewer.field(membership, :quarantined_at),
      prior_link_evidence: Reviewer.field(membership, :link_evidence),
      source_generation: Reviewer.field(membership, :source_generation),
      source_fingerprint: Reviewer.field(membership, :source_fingerprint),
      released_link_disposition: outcome.disposition,
      released_canonical_device_uid: outcome.canonical_device_uid,
      released_link_evidence: outcome.evidence
    }
  end

  defp default_transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, released} -> released
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp default_load_membership(membership_id) do
    case AwxHostMembership.get_by_id(membership_id, actor: Reviewer.store_actor()) do
      {:ok, %AwxHostMembership{} = membership} -> {:ok, membership}
      _ -> {:error, :membership_not_found}
    end
  end

  defp default_release_membership(membership, attrs, actor) do
    membership
    |> Ash.Changeset.for_update(:release_quarantine, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp default_record_release(attrs),
    do: AwxMembershipQuarantineReleaseRecord.record(attrs, actor: Reviewer.store_actor())
end
