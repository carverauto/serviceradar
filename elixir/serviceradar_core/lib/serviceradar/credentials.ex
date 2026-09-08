defmodule ServiceRadar.Credentials do
  @moduledoc """
  Shared credential metadata and matching rules for network integrations.

  Credentials are deployment-wide records, but rules scope their use to an
  edge agent, gateway, or partition and an SRQL target query.
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
    resource ServiceRadar.Credentials.CredentialBrokerGrant
    resource ServiceRadar.Credentials.CredentialSecretProvider
    resource ServiceRadar.Credentials.CredentialSecretResolutionAudit
    resource ServiceRadar.Credentials.NetworkCredentialSecret
    resource ServiceRadar.Credentials.NetworkCredentialSecretBinding
    resource ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit
    resource ServiceRadar.Credentials.NetworkCredentialRule
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
