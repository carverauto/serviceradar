defmodule ServiceRadarWebNGWeb.Admin do
  @moduledoc false

  # Depends on ServiceRadarWebNGWeb.Settings because the settings-catalog
  # redesign (redesign-settings-catalog-nav) folds these Admin pages (Jobs,
  # Edge Sites, Collectors, Edge/Plugin/Add-on packages, Dashboard packages)
  # into the Settings information architecture, so they render the shared
  # `Settings.Shell` catalog chrome. The reverse edge does not exist: the catalog
  # only names Admin LiveView modules as data, not as executable references.
  use Boundary,
    deps: [ServiceRadarWebNGWeb, ServiceRadarWebNGWeb.Settings],
    exports: :all
end
