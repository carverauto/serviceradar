defmodule ServiceRadarWebNG.Packages.RepoClientEgressTest do
  @moduledoc """
  Guards that `ServiceRadarWebNG.Packages.RepoClient` routes all external HTTP
  through the configured client (EgressClient by default) and never calls `Req`
  directly.

  The guard works by injecting a stub that records every `fetch_body/2` call and
  asserting the stub is invoked. If any code path inside `RepoClient` bypassed
  the injection and called `Req.get/2` directly, it would attempt a real network
  connection in CI and fail -- making the bypass visible rather than silent.
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Packages.RepoClient

  @moduletag :db_free

  defmodule RecordingClient do
    @moduledoc false

    def fetch_body(url, _opts) do
      send(self(), {:fetch_body_called, url})

      cond do
        String.ends_with?(url, "/repos/acme/demo") ->
          {:ok, %Req.Response{status: 200, body: ~s({"default_branch":"main"}), headers: %{}}}

        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "sha" => String.duplicate("b", 40),
                 "commit" => %{"verification" => %{"verified" => false, "reason" => "unsigned"}}
               }),
             headers: %{}
           }}

        String.contains?(url, "raw.githubusercontent.com/acme/demo") ->
          {:ok, %Req.Response{status: 200, body: "# synthetic fixture", headers: %{}}}

        String.contains?(url, "api.github.com/repos/acme/demo/releases/tags/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: ~s({"tag_name":"v1.0.0","assets":[]}),
             headers: %{}
           }}

        String.contains?(url, "api.github.com/repos/acme/demo/releases") ->
          body = Process.get(:release_list_body, ~s([{"tag_name":"v1.0.0","assets":[]}]))
          {:ok, %Req.Response{status: 200, body: body, headers: %{}}}

        true ->
          {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end
    end
  end

  defmodule StatusClient do
    @moduledoc false

    def fetch_body(_url, _opts) do
      {status, headers} = Process.get(:github_api_reply)
      {:ok, Req.Response.new(status: status, headers: headers, body: ~s({"message":"synthetic"}))}
    end
  end

  setup do
    repo = %{owner: "acme", repo: "demo"}
    opts = [http_client: RecordingClient]
    %{repo: repo, opts: opts}
  end

  test "resolve_ref routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, %{sha: sha}} = RepoClient.resolve_ref(repo, "main", opts)
    assert sha == String.duplicate("b", 40)

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
  end

  test "fetch_raw routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, body} = RepoClient.fetch_raw(repo, "main", "README.md", opts)
    assert body == "# synthetic fixture"

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "raw.githubusercontent.com")
  end

  test "fetch_release routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, release} = RepoClient.fetch_release(repo, "v1.0.0", opts)
    assert release["tag_name"] == "v1.0.0"

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
    assert String.contains?(url, "/releases/tags/")
  end

  test "fetch_recent_releases decodes raw JSON through the injected client", %{repo: repo, opts: opts} do
    assert {:ok, [%{"tag_name" => "v1.0.0", "assets" => []}]} =
             RepoClient.fetch_recent_releases(repo, 5, opts)

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
    assert String.contains?(url, "/releases")
  end

  test "fetch_recent_releases accepts empty and decoded lists and rejects invalid payloads", %{
    repo: repo,
    opts: opts
  } do
    error = {:error, "Plugin release browser returned an unexpected payload"}

    for {body, expected} <- [
          {"[]", {:ok, []}},
          {[%{"tag_name" => "v2.0.0"}], {:ok, [%{"tag_name" => "v2.0.0"}]}},
          {"{}", error},
          {"null", error},
          {"invalid JSON", error},
          {%{}, error}
        ] do
      Process.put(:release_list_body, body)
      assert RepoClient.fetch_recent_releases(repo, 5, opts) == expected
    end
  end

  describe "release endpoints answering 401, 403 or 429" do
    # An anonymous 403 or 429 carrying GitHub's rate-limit headers is the shared
    # hourly budget running out, not a credential problem; only a 401, or a 403
    # without those headers, is reported as one. CI exports GITHUB_TOKEN, so the
    # tokenless cases clear it for the duration of the test.
    setup do
      saved = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> if saved, do: System.put_env("GITHUB_TOKEN", saved) end)
    end

    test "rate-limit headers are reported as the rate limit; anything else stays a credential failure",
         %{repo: repo} do
      exhausted = [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1767225600"}]
      resets = "resets at 2026-01-01T00:00:00Z."
      raise_hint = " Attaching a GitHub access token raises the limit."

      cases = [
        {403, exhausted, nil, "GitHub API rate limit exceeded (HTTP 403); #{resets}#{raise_hint}"},
        {429, exhausted, nil, "GitHub API rate limit exceeded (HTTP 429); #{resets}#{raise_hint}"},
        {403, [{"retry-after", "60"}], nil,
         "GitHub API rate limit exceeded (HTTP 403); retry after 60 seconds.#{raise_hint}"},
        {403, [{"retry-after", "0"}], nil,
         "GitHub API rate limit exceeded (HTTP 403); retry after 0 seconds.#{raise_hint}"},
        {403,
         [
           {"x-ratelimit-remaining", "42"},
           {"x-ratelimit-reset", "1767225600"},
           {"retry-after", "60"}
         ], nil, "GitHub API rate limit exceeded (HTTP 403); retry after 60 seconds.#{raise_hint}"},
        {429,
         [
           {"x-ratelimit-remaining", "42"},
           {"x-ratelimit-reset", "1767225600"},
           {"retry-after", "0"}
         ], nil, "GitHub API rate limit exceeded (HTTP 429); retry after 0 seconds.#{raise_hint}"},
        {429, [], nil, "GitHub API rate limit exceeded (HTTP 429).#{raise_hint}"},
        {403, exhausted, "synthetic-token", "GitHub API rate limit exceeded (HTTP 403); #{resets}"},
        {403, [{"x-ratelimit-remaining", "42"}], nil,
         "Plugin repository requires authentication (HTTP 403); attach a GitHub access token."},
        {401, exhausted, "synthetic-token",
         "Plugin repository rejected the configured access token (HTTP 401); " <>
           "the token may be expired or missing repository read access."}
      ]

      for {status, headers, token, expected} <- cases do
        Process.put(:github_api_reply, {status, headers})
        opts = [http_client: StatusClient, github_token: token]

        assert RepoClient.fetch_release(repo, "v1.0.0", opts) == {:error, expected},
               "fetch_release: HTTP #{status} #{inspect(headers)}"

        assert RepoClient.fetch_recent_releases(repo, 5, opts) == {:error, expected},
               "fetch_recent_releases: HTTP #{status} #{inspect(headers)}"
      end
    end
  end
end
