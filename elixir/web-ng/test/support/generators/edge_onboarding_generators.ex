defmodule ServiceRadarWebNG.Generators.EdgeOnboardingGenerators do
  @moduledoc false

  import StreamData

  def package_id do
    string(:alphanumeric, min_length: 1, max_length: 64)
  end

  def download_token do
    string(:printable, min_length: 1, max_length: 128)
    |> map(&String.trim/1)
    |> filter(&(&1 != ""))
  end

  def core_api_url do
    one_of([
      constant(nil),
      constant("http://localhost:8090"),
      constant("https://example.com"),
      string(:alphanumeric, min_length: 1, max_length: 24)
      |> map(fn host -> "https://#{host}.test" end)
    ])
  end

  def random_token_string(opts \\ []) do
    max_length = Keyword.get(opts, :max_length, 400)
    string(:printable, max_length: max_length)
  end
end
