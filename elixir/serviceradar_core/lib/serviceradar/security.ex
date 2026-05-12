defmodule ServiceRadar.Security do
  @moduledoc """
  Ash domain for platform-security resources.

  Contains operator-managed records that back the webhook signature plug,
  brute-force lockouts, and the security event stream introduced by the
  platform-security-hardening change.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Security.WebhookSecret
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
