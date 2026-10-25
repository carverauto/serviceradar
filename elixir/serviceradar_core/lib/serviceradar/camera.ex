defmodule ServiceRadar.Camera do
  @moduledoc """
  Camera inventory domain for edge-routed live streaming.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain
    ]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Camera.Source
    resource ServiceRadar.Camera.StreamProfile
    resource ServiceRadar.Camera.RelaySession
    resource ServiceRadar.Camera.IngestOwner
    resource ServiceRadar.Camera.ConsumerLease
    resource ServiceRadar.Camera.RecorderClaim
    resource ServiceRadar.Camera.RecordingControlState
    resource ServiceRadar.Camera.RecordingBlock
    resource ServiceRadar.Camera.ArchiveBinding
    resource ServiceRadar.Camera.ArchiveQualificationReceipt
    resource ServiceRadar.Camera.ArchiveInitAuthority
    resource ServiceRadar.Camera.ArchiveUploadIntent
    resource ServiceRadar.Camera.ArchiveUploadDispatch
    resource ServiceRadar.Camera.AnalysisWorker
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
