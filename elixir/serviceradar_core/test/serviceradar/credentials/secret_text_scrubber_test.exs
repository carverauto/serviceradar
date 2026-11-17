defmodule ServiceRadar.Credentials.SecretTextScrubberTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.SecretTextScrubber

  # Invented values. A scheme-less authority is credential-bearing only when it
  # carries a password and names an IP literal or a dotted host (RFC 3986
  # authority without a scheme); the benign forms are ordinary Ansible host
  # patterns, tags and variable values.
  @credentialed [
    "viewer:hunter2@192.0.2.10",
    "viewer:hunter2@nvr_01.example.com",
    "viewer:hunter2@host01.example.com:8554/stream",
    "limit=viewer:hunter2@host01.example.com",
    "viewer:hunter2@[2001:db8::1]:554",
    "rtsp://viewer:hunter2@host01.example.com/stream",
    # Exactly the credential shape (user `deploy`, password `prod`), so it
    # cannot be told apart from a real credential.
    "deploy:prod@host01.example.com",
    # User `a`, password `b:c`: the first colon separates user and password.
    "a:b:c@host01.example.com"
  ]

  @benign [
    "ops@example.com",
    "deploy@host01.example.com",
    "webservers:&staging",
    "[2001:db8::1]",
    "12:30@noon",
    "group1:group2",
    "build_group:web_servers",
    "label: deploy@host01.example.com",
    "https://files.example.com/pkg.tgz?version=1.2.3#sha"
  ]

  describe "userinfo_url_input/1" do
    for value <- @credentialed do
      test "names the input holding #{inspect(value)}" do
        assert SecretTextScrubber.userinfo_url_input([
                 {"safe", "web01"},
                 {"target", unquote(value)}
               ]) ==
                 "target"
      end
    end

    for value <- @benign do
      test "accepts #{inspect(value)}" do
        assert SecretTextScrubber.userinfo_url_input([{"target", unquote(value)}]) == nil
      end
    end

    test "finds a scheme-less credential nested in lists and maps" do
      assert SecretTextScrubber.userinfo_url_input([
               {"mirrors", ["web01", %{"source" => "viewer:hunter2@192.0.2.10"}]}
             ]) == "mirrors"
    end
  end

  @scrub_text_cases [
    {"certificate issued for deploy@host01.example.com",
     "certificate issued for deploy@host01.example.com"},
    {"contact ops@example.com", "contact ops@example.com"},
    {"12:30@noon", "12:30@noon"},
    {"viewer:hunter2@nvr_01.example.com", "nvr_01.example.com"},
    {"label: deploy@host01.example.com", "label: deploy@host01.example.com"},
    {"certificate issued for deploy:prod@host01.example.com",
     "certificate issued for host01.example.com"},
    {"a:b:c@host01.example.com", "host01.example.com"},
    {"rtsp://viewer:hunter2@192.0.2.10:554/stream", "rtsp://192.0.2.10:554"}
  ]

  describe "scrub_text/1" do
    for {input, expected} <- @scrub_text_cases do
      test "scrubs #{inspect(input)} to #{inspect(expected)}" do
        assert SecretTextScrubber.scrub_text(unquote(input)) == unquote(expected)
      end
    end

    test "drops a scheme-less user and password and keeps the host" do
      assert SecretTextScrubber.scrub_text("dial viewer:hunter2@host01.example.com:8554 refused") ==
               "dial host01.example.com:8554 refused"

      assert SecretTextScrubber.scrub_text("auth failed for viewer:hunter2@192.0.2.10") ==
               "auth failed for 192.0.2.10"
    end
  end
end
