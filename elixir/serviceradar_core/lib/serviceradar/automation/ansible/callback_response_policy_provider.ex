defmodule ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider do
  @moduledoc """
  Supplies the reviewed, target-scoped public policy for an automation callback.

  The launch orchestrator owns the callback action, manifest, phase, operation,
  and desired state. A provider may supply only the complete target policy for
  the immutable AWX target snapshot. This keeps request input from selecting a
  callback URL, policy, principal, CA, or lifecycle phase.

  A production provider must return public SSH CA keys, opaque target
  principals, and the applicable transaction/retirement policy for every
  target. Until such a provider is configured, callback-enabled launches fail
  closed before any database row is created.
  """

  @type context :: %{
          required(:action) => binary(),
          required(:action_version) => binary(),
          required(:policy_version) => binary(),
          required(:tenant_id) => binary(),
          required(:controller_id) => binary(),
          required(:inventory_id) => pos_integer(),
          required(:job_template_id) => pos_integer(),
          required(:binding_id) => binary(),
          required(:binding_version) => pos_integer(),
          required(:approval_id) => binary(),
          required(:approval_expires_at) => binary(),
          required(:reviewed_by_principal_type) => binary(),
          required(:reviewed_by_principal_id) => binary(),
          required(:reviewed_at) => binary(),
          required(:scm_revision) => binary(),
          required(:content_sha256) => binary(),
          required(:targets) => [map()]
        }

  @callback snapshot(context()) ::
              {:ok, %{required(:targets) => [map()]}}
              | {:ok, %{required(binary()) => term()}}
              | {:error, term()}
end

defmodule ServiceRadar.Automation.Ansible.UnavailableCallbackResponsePolicyProvider do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.CallbackResponsePolicyProvider

  @impl true
  def snapshot(_context), do: {:error, :callback_response_policy_unavailable}
end
