defmodule ServiceRadar.PrefixTags.ProviderSourceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.ProviderSource
  alias ServiceRadar.PrefixTags.Store

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "provider_for_ip extracts provider name from trie tags" do
    Store.put_rows("provider", [
      %{prefix: "10.0.0.0/8", tags: ["provider:aws"], source: "provider"},
      %{prefix: "10.1.0.0/16", tags: ["provider:aws", "provider:aws-us-east"], source: "provider"}
    ])

    # Most-specific match first → first tag on that entry
    assert ProviderSource.provider_for_ip("10.1.2.3") == "aws"
    assert ProviderSource.provider_for_ip("8.8.8.8") == nil
  end

  test "source_name is provider" do
    assert ProviderSource.source_name() == "provider"
  end
end
