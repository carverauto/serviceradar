defmodule ServiceRadar.Automation.Ansible.AwxMembershipApproval do
  @moduledoc """
  Human approval boundary for one proposed AWX host membership.

  The request carries the complete source tuple and the generation,
  fingerprint, and canonical link-evidence digest shown to the reviewer. The
  service reloads the user and role profile from storage, ignores permissions
  cached in the caller's scope, and performs a compare-and-swap update over the
  exact current proposal. Reconciliation can propose or quarantine a link, but
  it cannot call this service as a system actor to approve one.
  """

  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipReviewer, as: Reviewer

  @request_keys ~w(
    membership_id
    controller_id
    inventory_id
    awx_host_id
    canonical_device_uid
    source_generation
    source_fingerprint
    link_evidence_digest
  )
  @source_evidence_keys MapSet.new(~w(
    kind
    controller_id
    inventory_id
    awx_host_id
    matching_device_uids
    match_count
  ))

  @type approval_request :: %{
          membership_id: String.t(),
          controller_id: String.t(),
          inventory_id: pos_integer(),
          awx_host_id: pos_integer(),
          canonical_device_uid: String.t(),
          source_generation: pos_integer() | String.t(),
          source_fingerprint: String.t(),
          link_evidence_digest: String.t()
        }

  @doc """
  Approves one exact proposed membership as the currently logged-in human.

  A `ServiceRadarWebNG.Accounts.Scope`-shaped map or the user actor itself may
  be passed as the second argument. The caller's cached permission set is never
  used as approval authority.
  """
  @spec approve(map(), map()) :: {:ok, AwxHostMembership.t()} | {:error, term()}
  def approve(request, scope_or_actor), do: approve(request, scope_or_actor, [])

  @doc false
  @spec approve(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve(request, scope_or_actor, opts) when is_map(request) and is_list(opts) do
    dependencies = dependencies(opts)

    with {:ok, request} <-
           Reviewer.normalize_request(request, @request_keys, :invalid_approval_request),
         {:ok, authorized_actor} <- Reviewer.authorize(scope_or_actor, dependencies),
         {:ok, membership} <- load_membership(dependencies, request.membership_id),
         :ok <- validate_membership(membership, request),
         approved_at = dependencies.now.(),
         true <- is_struct(approved_at, DateTime) || {:error, :approval_clock_invalid},
         attrs = approval_attributes(request, membership, approved_at),
         {:ok, approved} <-
           dependencies.approve_membership.(membership, attrs, authorized_actor) do
      {:ok, approved}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :membership_approval_denied}
    end
  rescue
    _ -> {:error, :membership_approval_denied}
  end

  def approve(_request, _scope_or_actor, _opts), do: {:error, :invalid_approval_request}

  @doc "Returns the canonical digest a reviewer must bind to the displayed link evidence."
  @spec link_evidence_digest(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate link_evidence_digest(evidence), to: Reviewer

  defp dependencies(opts) do
    defaults = %{
      load_membership: &default_load_membership/1,
      approve_membership: &default_approve_membership/3,
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

  defp validate_membership(membership, request) do
    with :ok <- Reviewer.exact_source_identity(membership, request),
         :ok <- Reviewer.exact_source_evidence(membership, request),
         :ok <- current_proposal(membership),
         :ok <- exact_device_link(membership, request) do
      unambiguous_evidence(membership, request)
    end
  end

  defp current_proposal(membership) do
    cond do
      field(membership, :current) != true or field(membership, :enabled) != true or
          not is_nil(field(membership, :expired_at)) ->
        {:error, :membership_not_current}

      field(membership, :link_disposition) != :proposed ->
        {:error, :membership_not_proposed}

      true ->
        :ok
    end
  end

  defp exact_device_link(membership, request) do
    if field(membership, :canonical_device_uid) == request.canonical_device_uid,
      do: :ok,
      else: {:error, :membership_identity_changed}
  end

  defp unambiguous_evidence(membership, request) do
    evidence = field(membership, :link_evidence)

    with true <- is_map(evidence),
         {:ok, evidence} <- Reviewer.string_keyed(evidence),
         true <- MapSet.new(Map.keys(evidence)) == @source_evidence_keys,
         true <- evidence["kind"] == "stored_awx_source_tuple",
         true <- canonical_string(evidence["controller_id"]) == request.controller_id,
         true <- evidence["inventory_id"] == request.inventory_id,
         true <- evidence["awx_host_id"] == request.awx_host_id,
         true <- evidence["matching_device_uids"] == [request.canonical_device_uid],
         true <- evidence["match_count"] == 1 do
      :ok
    else
      _ -> {:error, :membership_link_ambiguous}
    end
  end

  defp approval_attributes(request, membership, approved_at) do
    %{
      controller_id: request.controller_id,
      inventory_id: request.inventory_id,
      awx_host_id: request.awx_host_id,
      canonical_device_uid: request.canonical_device_uid,
      source_generation: request.source_generation,
      source_fingerprint: request.source_fingerprint,
      expected_link_evidence: field(membership, :link_evidence),
      link_evidence_digest: request.link_evidence_digest,
      approved_at: approved_at
    }
  end

  defp default_load_membership(membership_id) do
    case AwxHostMembership.get_by_id(membership_id, actor: Reviewer.store_actor()) do
      {:ok, %AwxHostMembership{} = membership} -> {:ok, membership}
      _ -> {:error, :membership_not_found}
    end
  end

  defp default_approve_membership(membership, attrs, actor) do
    membership
    |> Ash.Changeset.for_update(:approve_link, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp canonical_string(nil), do: nil
  defp canonical_string(value), do: value |> to_string() |> String.downcase()

  defp field(struct_or_map, key), do: Reviewer.field(struct_or_map, key)
end
