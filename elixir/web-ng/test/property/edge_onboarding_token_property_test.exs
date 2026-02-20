defmodule ServiceRadarWebNG.EdgeOnboardingTokenPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ServiceRadarWebNG.Edge.OnboardingToken
  alias ServiceRadarWebNG.Generators.EdgeOnboardingGenerators
  alias ServiceRadarWebNG.TestSupport.PropertyOpts

  property "edge onboarding tokens round-trip and are base64url (no padding)" do
    check all(
            package_id <- EdgeOnboardingGenerators.package_id(),
            download_token <- EdgeOnboardingGenerators.download_token(),
            api <- EdgeOnboardingGenerators.core_api_url(),
            max_runs: PropertyOpts.max_runs()
          ) do
      assert {:ok, token} = OnboardingToken.encode(package_id, download_token, api)
      assert String.starts_with?(token, "edgepkg-v1:")
      assert token =~ ~r/^edgepkg-v1:[A-Za-z0-9_-]+$/

      assert {:ok, payload} = OnboardingToken.decode(token)

      expected =
        %{pkg: package_id, dl: download_token}
        |> maybe_put_api(api)

      assert payload == expected
    end
  end

  property "edge onboarding token decode never crashes for random strings" do
    check all(
            raw <- EdgeOnboardingGenerators.random_token_string(),
            max_runs: PropertyOpts.max_runs(:slow_property)
          ) do
      result = OnboardingToken.decode(raw)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  defp maybe_put_api(payload, nil), do: payload

  defp maybe_put_api(payload, api) when is_binary(api) do
    api = String.trim(api)
    if api == "", do: payload, else: Map.put(payload, :api, api)
  end
end
