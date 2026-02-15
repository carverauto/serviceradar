defmodule ServiceRadar.Software do
  @moduledoc """
  The Software domain manages firmware/software image library, TFTP sessions,
  and storage configuration for network device firmware management.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Software.SoftwareImage
    resource ServiceRadar.Software.StorageConfig
    resource ServiceRadar.Software.TftpSession
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
