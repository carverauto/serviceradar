defmodule ServiceRadarWebNG.Edge do
  alias ServiceRadarWebNG.Edge.OnboardingToken

  def encode_onboarding_token(package_id, download_token, core_api_url \\ nil) do
    OnboardingToken.encode(package_id, download_token, core_api_url)
  end

  def decode_onboarding_token(token) do
    OnboardingToken.decode(token)
  end
end
