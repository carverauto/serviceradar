defmodule ServiceRadar.NetworkChanges do
  @moduledoc """
  Domain for proposed and recorded network changes.

  Windows, selectors, comments and status live in CNPG. Dgraph holds the
  Change node and `change.affects` edges for impact walks. ServiceRadar
  does not emit postpone/sequence verdicts.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.NetworkChanges.Change
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
