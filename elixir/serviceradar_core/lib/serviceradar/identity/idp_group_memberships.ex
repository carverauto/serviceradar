defmodule ServiceRadar.Identity.IdpGroupMemberships do
  @moduledoc """
  Reconciles a user's identity-provider-sourced group memberships at sign-in.

  Group memberships back access grants -- dashboard sharing, device group grants
  -- and were previously maintained entirely by hand, so an IdP group and the
  ServiceRadar group of the same name were two unrelated lists that drifted.

  Reconciliation is deliberately narrow: it adds memberships for the groups a
  user's claims currently map to, and withdraws only those it previously added
  itself. A membership an operator created is never touched, because the
  identity provider knows nothing about it and "the claim did not arrive" is not
  evidence that an operator's decision was wrong.
  """

  alias ServiceRadar.Identity.PrivilegedMembership

  @type result :: %{added: [String.t()], withdrawn: [String.t()], kept: [String.t()]}

  @doc """
  Makes the user's IdP-sourced memberships match `group_ids`.

  Returns which memberships were added, withdrawn, and left alone. Errors on
  individual rows are logged and skipped rather than raised: a sign-in must not
  fail because one group could not be reconciled, and the caller has already
  applied the role and profile by this point.
  """
  @spec sync(String.t(), [String.t()], keyword()) ::
          result() | {:error, :outer_transaction_not_supported}
  def sync(user_id, group_ids, opts \\ [])

  def sync(user_id, group_ids, opts),
    do: PrivilegedMembership.reconcile_idp(user_id, group_ids, opts)
end
