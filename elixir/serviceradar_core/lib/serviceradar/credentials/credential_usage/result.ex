defmodule ServiceRadar.Credentials.CredentialUsage.Result do
  @moduledoc "Redacted, complete usage result for one reusable credential."

  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.LiveGrant

  defstruct status: :available,
            managed_by: :operator,
            management_label: nil,
            consumers: [],
            live_grants: []

  @type t :: %__MODULE__{
          status: :available,
          managed_by: :operator | :control_plane,
          management_label: String.t() | nil,
          consumers: [Consumer.t()],
          live_grants: [LiveGrant.t()]
        }
end
