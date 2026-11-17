defmodule ServiceRadar.Camera do
  @moduledoc """
  Camera inventory domain for edge-routed live streaming.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain,
      AshAdmin.Domain,
      AshPaperTrail.Domain
    ]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.Source
    resource ServiceRadar.Camera.StreamProfile
    resource ServiceRadar.Camera.RelaySession
    resource ServiceRadar.Camera.IngestOwner
    resource ServiceRadar.Camera.ConsumerLease
    resource ServiceRadar.Camera.RecorderClaim
    resource ServiceRadar.Camera.RecordingControlState
    resource ServiceRadar.Camera.RecordingArchiveSettings
    resource ServiceRadar.Camera.CameraRecordingPolicy
    resource ServiceRadar.Camera.NVRStorageSettings
    resource ServiceRadar.Camera.LocalPublicationIntent
    resource ServiceRadar.Camera.RecordingBlock
    resource ServiceRadar.Camera.RecordingCatalogEntry
    resource ServiceRadar.Camera.RecordingGap
    resource ServiceRadar.Camera.RecordingHold
    resource ServiceRadar.Camera.RecordingDisposition
    resource ServiceRadar.Camera.RecordingAccessAudit
    resource ServiceRadar.Camera.ArchiveBinding
    resource ServiceRadar.Camera.NVRArchiveReceipt
    resource ServiceRadar.Camera.RecordingOperation
    resource ServiceRadar.Camera.LocalStorageBinding
    resource ServiceRadar.Camera.LocalStorageHistoryGenesis
    resource ServiceRadar.Camera.LocalStorageBootstrapInstallation
    resource ServiceRadar.Camera.LocalStorageBootstrapPreparation
    resource ServiceRadar.Camera.LocalStorageQualification
    resource ServiceRadar.Camera.LocalStorageQualificationReport
    resource ServiceRadar.Camera.ArchiveQualificationReceipt
    resource ServiceRadar.Camera.ArchiveInitAuthority
    resource ServiceRadar.Camera.ArchiveManifestAuthority
    resource ServiceRadar.Camera.ArchiveMediaAuthority
    resource ServiceRadar.Camera.ArchiveUploadIntent
    resource ServiceRadar.Camera.ArchiveUploadDispatch
    resource ServiceRadar.Camera.AnalysisWorker
    resource ServiceRadar.Storage.StorageEntitlement
    resource ServiceRadar.Storage.StorageUsageDailyReport
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
