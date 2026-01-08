defmodule ServiceRadar.Identity.Token do
  @moduledoc """
  Token resource for AshAuthentication.

  Stores authentication tokens (session, magic link, password reset, etc.)
  with configurable expiration and purpose.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "user_tokens"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]
  end
end
