defmodule ServiceRadarWebNG.Plugins.FirstPartyReleaseClientAuthTest do
  @moduledoc """
  Guards the two rules that decide where a repository's access token is allowed
  to travel.

  Both are easy to break by accident and neither fails loudly when broken: a
  token that stops being sent turns a private repository into "the release list
  is empty", and a token that is sent one hop too far is disclosed to a host
  that never needed it while the download still succeeds.
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient, as: Client

  @moduletag :db_free

  defmodule StubClient do
    @moduledoc false

    # Records every request, then answers: the first hop 302s to the pre-signed
    # host, the second returns bytes. That shape is the whole point -- the test
    # is about which of the two carries Authorization.
    def get(url, opts) do
      headers = Keyword.get(opts, :headers, [])
      send(self(), {:request, url, headers})

      if String.contains?(url, "objects.githubusercontent.com") do
        {:ok, %Req.Response{status: 200, body: "BUNDLE", headers: %{}}}
      else
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["https://objects.githubusercontent.com/signed/abc"]}
         }}
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, StubClient)

    previous_token = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_github_token)
    Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_github_token)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, previous)
      end

      if is_nil(previous_token) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_github_token)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_github_token, previous_token)
      end
    end)

    {:ok, repo} = Client.parse_repo_url("https://github.com/acme/sr-plugins")
    %{repo: repo}
  end

  defp collect_requests(acc \\ []) do
    receive do
      {:request, url, headers} -> collect_requests([{url, headers} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp authorization(headers) do
    Enum.find_value(headers, fn
      {"authorization", value} -> value
      _ -> nil
    end)
  end

  describe "private repository asset download" do
    test "uses the API asset URL, not browser_download_url", %{repo: repo} do
      repo = Client.with_token(repo, "ghp_secret")

      asset = %{
        "url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42",
        "browser_download_url" => "https://github.com/acme/sr-plugins/releases/download/v1/bundle.zip"
      }

      assert {:ok, "BUNDLE"} = Client.fetch_binary_asset(repo, asset)

      [{first_url, _} | _] = collect_requests()

      # browser_download_url 404s for a PAT; only the API endpoint serves a
      # private repository's asset bytes.
      assert first_url == "https://api.github.com/repos/acme/sr-plugins/releases/assets/42"
    end

    test "asks for octet-stream so GitHub returns bytes rather than asset JSON", %{repo: repo} do
      repo = Client.with_token(repo, "ghp_secret")
      asset = %{"url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42"}

      assert {:ok, _} = Client.fetch_binary_asset(repo, asset)

      [{_, headers} | _] = collect_requests()
      assert Enum.any?(headers, &match?({"accept", "application/octet-stream"}, &1))
    end

    test "sends the repository token on the API hop", %{repo: repo} do
      repo = Client.with_token(repo, "ghp_secret")
      asset = %{"url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42"}

      assert {:ok, _} = Client.fetch_binary_asset(repo, asset)

      [{_, headers} | _] = collect_requests()
      assert authorization(headers) == "Bearer ghp_secret"
    end

    test "does NOT forward the token to the pre-signed redirect target", %{repo: repo} do
      repo = Client.with_token(repo, "ghp_secret")
      asset = %{"url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42"}

      assert {:ok, "BUNDLE"} = Client.fetch_binary_asset(repo, asset)

      requests = collect_requests()
      assert length(requests) == 2

      {redirect_url, redirect_headers} = List.last(requests)
      assert String.contains?(redirect_url, "objects.githubusercontent.com")

      # The pre-signed URL carries its own authorization. Forwarding the PAT
      # discloses it to a host that has no business seeing it.
      assert authorization(redirect_headers) == nil
    end
  end

  describe "public repository" do
    test "uses browser_download_url when no token is bound", %{repo: repo} do
      asset = %{
        "url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42",
        "browser_download_url" => "https://github.com/acme/sr-plugins/releases/download/v1/bundle.zip"
      }

      assert {:ok, "BUNDLE"} = Client.fetch_binary_asset(repo, asset)

      [{first_url, _} | _] = collect_requests()
      assert first_url == "https://github.com/acme/sr-plugins/releases/download/v1/bundle.zip"
    end
  end

  describe "token selection" do
    test "the repository's token wins over the global environment token", %{repo: repo} do
      Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_github_token, "ghp_global")
      repo = Client.with_token(repo, "ghp_repo")
      asset = %{"url" => "https://api.github.com/repos/acme/sr-plugins/releases/assets/42"}

      assert {:ok, _} = Client.fetch_binary_asset(repo, asset)

      [{_, headers} | _] = collect_requests()
      assert authorization(headers) == "Bearer ghp_repo"
    end

    test "the global token remains the fallback for a repository without one", %{repo: repo} do
      # This is what keeps the built-in first-party source working exactly as it
      # did before repositories became records.
      Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_github_token, "ghp_global")
      asset = %{"browser_download_url" => "https://github.com/acme/sr-plugins/releases/download/v1/b.zip"}

      assert {:ok, _} = Client.fetch_binary_asset(repo, asset)

      [{_, headers} | _] = collect_requests()
      assert authorization(headers) == "Bearer ghp_global"
    end
  end

  describe "parse_repo_url/1 delegates to the core parser" do
    test "normalizes a .git suffix so the unique index sees one value" do
      assert {:ok, %{repo_url: "https://github.com/acme/sr-plugins"}} =
               Client.parse_repo_url("https://github.com/acme/sr-plugins.git")
    end

    test "rejects a non-GitHub host" do
      assert {:error, _} = Client.parse_repo_url("https://gitlab.com/acme/sr-plugins")
    end

    test "rejects a URL with no repository segment" do
      assert {:error, _} = Client.parse_repo_url("https://github.com/acme")
    end
  end

  describe "missing_release?/1" do
    test "matches an exact-tag 404, including the private-repository hint" do
      reason =
        "Release tag v1.4.51 was not found. If this repository is private, attach a GitHub access token to it: " <>
          "an unauthenticated request cannot see private repositories and GitHub reports that as 404."

      assert Client.missing_release?(reason)
    end

    test "matches a private-repository releases list 404" do
      assert Client.missing_release?("Repository or releases not found")
    end

    test "does not treat credential or transport failures as a missing catalog" do
      refute Client.missing_release?(
               "Plugin repository requires authentication (HTTP 401); attach a GitHub access token."
             )

      refute Client.missing_release?("Release import failed with HTTP 502")
      refute Client.missing_release?(:timeout)
    end
  end

  describe "resolve_catalog/3" do
    test "uses the exact deployed tag when GitHub has that release" do
      exact = fn "v1.4.51" -> {:ok, [:from_exact]} end
      recent = fn -> {:ok, [:from_recent]} end

      assert {:ok, [:from_exact], :exact} = Client.resolve_catalog("v1.4.51", exact, recent)
    end

    test "falls back to recent releases when the deployed tag is unpublished" do
      exact = fn "v1.4.51" ->
        {:error, "Release tag v1.4.51 was not found. If this repository is private, attach a token."}
      end

      recent = fn -> {:ok, [:from_recent]} end

      assert {:ok, [:from_recent], :recent} = Client.resolve_catalog("v1.4.51", exact, recent)
    end

    test "does not fall back when the exact tag fails for a reason other than 404" do
      exact = fn "v1.4.51" ->
        {:error, "Plugin repository requires authentication (HTTP 401); attach a GitHub access token."}
      end

      recent = fn -> {:ok, [:from_recent]} end

      assert {:error, "Plugin repository requires authentication (HTTP 401); attach a GitHub access token."} =
               Client.resolve_catalog("v1.4.51", exact, recent)
    end

    test "scans recent releases when no deployed tag is configured" do
      exact = fn _tag -> flunk("exact lookup must not run without a tag") end
      recent = fn -> {:ok, [:from_recent]} end

      assert {:ok, [:from_recent], :recent} = Client.resolve_catalog(nil, exact, recent)
      assert {:ok, [:from_recent], :recent} = Client.resolve_catalog("", exact, recent)
    end

    test "reports the fallback feed as an error when recent releases fail too" do
      exact = fn "v1.4.51" ->
        {:error, "Release tag v1.4.51 was not found. If this repository is private, attach a token."}
      end

      recent = fn -> {:error, "Repository or releases not found"} end

      assert {:error, "Repository or releases not found"} =
               Client.resolve_catalog("v1.4.51", exact, recent)
    end
  end
end
