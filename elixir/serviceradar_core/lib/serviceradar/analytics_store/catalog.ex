defmodule ServiceRadar.AnalyticsStore.Catalog do
  @moduledoc """
  Ash domain for analytics-store catalog tables on the primary (manifest).
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.AnalyticsStore.FileManifest
    resource ServiceRadar.AnalyticsStore.DeliveryReceipt
    resource ServiceRadar.AnalyticsStore.ArchiveBatch
  end
end
