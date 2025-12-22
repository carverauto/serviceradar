defmodule ServiceRadarWebNG.Edge do
  @moduledoc """
  The Edge context for managing edge onboarding operations.

  This context provides functions for:
  - Creating and managing edge onboarding packages
  - Recording and querying audit events
  - Token encoding/decoding for package delivery

  ## Submodules

  - `ServiceRadarWebNG.Edge.OnboardingPackages` - Package CRUD operations
  - `ServiceRadarWebNG.Edge.OnboardingEvents` - Audit event recording
  - `ServiceRadarWebNG.Edge.OnboardingToken` - Token encoding/decoding
  - `ServiceRadarWebNG.Edge.Crypto` - Cryptographic utilities
  """

  alias ServiceRadarWebNG.Edge.OnboardingToken
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.OnboardingEvents

  # Delegate token operations
  defdelegate encode_onboarding_token(package_id, download_token, core_api_url \\ nil), to: OnboardingToken, as: :encode
  defdelegate decode_onboarding_token(token), to: OnboardingToken, as: :decode

  # Delegate package operations
  defdelegate list_packages(filters \\ %{}), to: OnboardingPackages, as: :list
  defdelegate get_package(id), to: OnboardingPackages, as: :get
  defdelegate get_package!(id), to: OnboardingPackages, as: :get!
  defdelegate create_package(attrs, opts \\ []), to: OnboardingPackages, as: :create
  defdelegate deliver_package(id, token, opts \\ []), to: OnboardingPackages, as: :deliver
  defdelegate revoke_package(id, opts \\ []), to: OnboardingPackages, as: :revoke
  defdelegate delete_package(id, opts \\ []), to: OnboardingPackages, as: :delete
  defdelegate package_defaults(), to: OnboardingPackages, as: :defaults

  # Delegate event operations
  defdelegate list_package_events(package_id, opts \\ []), to: OnboardingEvents, as: :list_for_package
  defdelegate record_package_event(package_id, event_type, opts \\ []), to: OnboardingEvents, as: :record
  defdelegate recent_events(opts \\ []), to: OnboardingEvents, as: :recent
end
