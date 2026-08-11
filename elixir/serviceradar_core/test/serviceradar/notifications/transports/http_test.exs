defmodule ServiceRadar.Notifications.Transports.HTTPTest do
  @moduledoc """
  The shared outbound HTTP path for the native transports.

  Every test is `async: true` and none of them opens a socket. Two seams make
  that possible and both are the ones the module documents:

    * `req_options: [plug: fun]` - Req calls the function with a `Plug.Conn`
      instead of making a request, so a "destination" is a two-line function that
      can also assert on what it was sent.
    * `req_options: [adapter: fun]` - the adapter returns an exception, which is
      how a timeout, a refused connection, or a TLS failure is produced without
      one existing.

  The URL is a **public IP literal** on purpose. `validate_https_public_url/2`
  resolves a hostname through DNS, and a test that needed DNS would be a test
  that fails on a laptop in a tunnel.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP

  # Public address, parsed directly by `:inet.parse_address/1`, so the policy
  # never resolves a name. The path deliberately looks like a Slack/Discord
  # webhook path: those carry the credential in the path, and no error this
  # module produces may echo it.
  @url "https://93.184.216.34/services/T00000/B00000/n2NcJmqQmY7GhLpVvRtXwZaB"
  # Unique to this file. `capture_log/1` in an async suite can pick up other
  # tests' output, so the value asserted on must not be one another file could
  # plausibly emit.
  @secret "http-test-secret-6f1c4a9e-not-a-real-credential"

  describe "post/3 outbound URL policy" do
    test "refuses http:// and makes no request" do
      assert {:error, {:blocked_url, :disallowed_scheme}} =
               HTTP.post("http://93.184.216.34/hook", %{}, req_options: [plug: recording_plug()])

      refute_received {:http_request, _request}
    end

    test "refuses localhost" do
      assert {:error, {:blocked_url, :disallowed_host}} =
               HTTP.post("https://localhost/hook", %{}, req_options: [plug: recording_plug()])

      refute_received {:http_request, _request}
    end

    test "refuses loopback and private addresses" do
      for host <- ["127.0.0.1", "10.1.2.3", "192.168.10.10", "172.16.0.9", "169.254.169.254"] do
        assert {:error, {:blocked_url, :disallowed_host}} =
                 HTTP.post("https://#{host}/hook", %{}, req_options: [plug: recording_plug()])
      end

      refute_received {:http_request, _request}
    end

    test "refuses a non-standard port unless the caller opts in" do
      assert {:error, {:blocked_url, :disallowed_port}} =
               HTTP.post("https://93.184.216.34:8443/hook", %{}, [])

      assert {:ok, %{status: 200}} =
               HTTP.post("https://93.184.216.34:8443/hook", %{},
                 allowed_ports: [443, 8443],
                 req_options: [plug: json_plug(200, %{})]
               )
    end

    test "refuses a value that is not a URL string" do
      assert {:error, {:blocked_url, _reason}} = HTTP.post(nil, %{}, [])
      assert {:error, {:blocked_url, :invalid_url}} = HTTP.post("", %{}, [])
      assert {:error, {:blocked_url, :invalid_url}} = HTTP.post("not a url", %{}, [])
    end
  end

  describe "post/3" do
    test "sends the JSON body and returns status, headers, and decoded body" do
      plug =
        json_plug(200, %{"ok" => true, "ts" => "1700000000.000100"}, [{"x-request-id", "req-7"}])

      assert {:ok, response} =
               HTTP.post(@url, %{"text" => "disk full"}, req_options: [plug: plug])

      assert response.status == 200
      assert response.body == %{"ok" => true, "ts" => "1700000000.000100"}
      assert HTTP.header(response, "x-request-id") == "req-7"

      assert_received {:http_request, request}
      assert request.method == "POST"
      assert Jason.decode!(request.body) == %{"text" => "disk full"}
      assert header(request, "content-type") =~ "application/json"
    end

    test "does not follow a redirect, so a 302 cannot walk past the URL policy" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
        |> Plug.Conn.resp(302, "")
      end

      assert {:ok, %{status: 302}} = HTTP.post(@url, %{}, req_options: [plug: plug])
    end

    test "renders bearer auth into an Authorization header" do
      assert {:ok, _response} =
               HTTP.post(@url, %{},
                 auth: {:bearer, @secret},
                 sensitive_values: [@secret],
                 req_options: [plug: json_plug(200, %{})]
               )

      assert_received {:http_request, request}
      assert header(request, "authorization") == "Bearer " <> @secret
    end

    test "renders basic auth into an Authorization header" do
      assert {:ok, _response} =
               HTTP.post(@url, %{},
                 auth: {:basic, "svc-notify", @secret},
                 req_options: [plug: json_plug(200, %{})]
               )

      assert_received {:http_request, request}

      assert header(request, "authorization") ==
               "Basic " <> Base.encode64("svc-notify:" <> @secret)
    end

    test "renders a named auth header" do
      assert {:ok, _response} =
               HTTP.post(@url, %{},
                 auth: {:header, "X-API-Key", @secret},
                 req_options: [plug: json_plug(200, %{})]
               )

      assert_received {:http_request, request}
      assert header(request, "x-api-key") == @secret
    end

    test "carries operator headers and drops nil values" do
      assert {:ok, _response} =
               HTTP.post(@url, %{},
                 headers: %{"X-Source" => "serviceradar", "X-Absent" => nil},
                 req_options: [plug: json_plug(200, %{})]
               )

      assert_received {:http_request, request}
      assert header(request, "x-source") == "serviceradar"
      assert header(request, "x-absent") == nil
    end
  end

  describe "post/3 transport failures" do
    test "normalises the reasons that matter to a closed atom vocabulary" do
      for {reason, class} <- [
            {:timeout, :timeout},
            {:etimedout, :timeout},
            {:closed, :closed},
            {:econnreset, :closed},
            {:econnrefused, :econnrefused},
            {:nxdomain, :nxdomain},
            {{:tls_alert, {:handshake_failure, ~c"bad cert"}}, :tls},
            {:ehostunreach, :unknown}
          ] do
        assert {:error, {^class, detail}} =
                 HTTP.post(@url, %{}, req_options: [adapter: failing(reason)])

        assert is_binary(detail)
      end
    end

    test "never echoes the URL path, only the host" do
      assert {:error, {:timeout, detail}} =
               HTTP.post(@url, %{}, req_options: [adapter: failing(:timeout)])

      assert detail =~ "93.184.216.34"
      refute detail =~ "n2NcJmqQmY7GhLpVvRtXwZaB"
    end

    test "a raising plug becomes an error rather than a crash" do
      plug = fn _conn -> raise "destination exploded" end

      assert {:error, {:unknown, detail}} = HTTP.post(@url, %{}, req_options: [plug: plug])
      assert detail =~ "93.184.216.34"
    end
  end

  describe "to_result/2 status classification" do
    test "2xx is delivered and carries the correlation id the caller extracted" do
      result =
        HTTP.to_result({:ok, %{status: 201, headers: %{}, body: %{}}},
          external_correlation_id: "1700000000.000100"
        )

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "1700000000.000100"
      assert result.result_summary["http_status"] == 201
    end

    test "5xx is retryable" do
      result = HTTP.to_result({:ok, %{status: 503, headers: %{}, body: "unavailable"}})

      assert %Result{disposition: :retryable_failure, error_class: "http_503"} = result
      assert Result.outcome(result, true) == :retry
      assert Result.outcome(result, false) == :failed
    end

    test "429 is retryable and honours Retry-After" do
      response = %{status: 429, headers: %{"retry-after" => ["30"]}, body: ""}
      result = HTTP.to_result({:ok, response})

      assert %Result{disposition: :retryable_failure, error_class: "http_429"} = result
      assert result.retry_after_ms == 30_000
    end

    test "408 is retryable" do
      assert %Result{disposition: :retryable_failure, error_class: "http_408"} =
               HTTP.to_result({:ok, %{status: 408, headers: %{}, body: ""}})
    end

    test "400 is permanent, so a payload that will never be accepted stops costing attempts" do
      result =
        HTTP.to_result({:ok, %{status: 400, headers: %{}, body: %{"error" => "invalid_blocks"}}})

      assert %Result{disposition: :permanent_failure, error_class: "http_400"} = result
      assert result.error_message =~ "invalid_blocks"
      assert Result.outcome(result, true) == :failed
    end

    test "404 is permanent" do
      assert %Result{disposition: :permanent_failure, error_class: "http_404"} =
               HTTP.to_result({:ok, %{status: 404, headers: %{}, body: ""}})
    end
  end

  describe "to_result/2 transport failures" do
    test "a timeout is retryable" do
      result = HTTP.to_result({:error, {:timeout, "timeout contacting example: timeout"}})

      assert %Result{disposition: :retryable_failure, error_class: "timeout"} = result
      assert Result.outcome(result, true) == :retry
    end

    test "a connection failure is retryable" do
      for class <- [:closed, :econnrefused, :nxdomain, :tls, :unknown] do
        result = HTTP.to_result({:error, {class, "boom"}})
        assert %Result{disposition: :retryable_failure} = result
        assert result.error_class == Atom.to_string(class)
      end
    end

    test "a blocked URL is permanent, because repeating it cannot make it public" do
      for reason <- [:disallowed_scheme, :disallowed_host, :disallowed_port, :invalid_url] do
        result = HTTP.to_result({:error, {:blocked_url, reason}})

        assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
        assert Result.outcome(result, true) == :failed
      end
    end

    test "an unresolvable host is the one policy rejection that is retryable" do
      result = HTTP.to_result({:error, {:blocked_url, :dns_resolution_failed}})

      assert %Result{disposition: :retryable_failure, error_class: "dns_resolution_failed"} =
               result

      assert Result.outcome(result, true) == :retry
    end
  end

  describe "secrets" do
    test "a secret echoed by the destination is scrubbed out of the error message" do
      response = %{status: 400, headers: %{}, body: %{"error" => "bad token #{@secret}"}}

      result = HTTP.to_result({:ok, response}, sensitive_values: [@secret])

      refute result.error_message =~ @secret
      assert result.error_message =~ "[REDACTED]"
    end

    test "a secret in a transport error detail is scrubbed" do
      plug = fn _conn -> raise "handshake rejected for token #{@secret}" end

      assert {:error, {:unknown, detail}} =
               HTTP.post(@url, %{},
                 auth: {:bearer, @secret},
                 sensitive_values: [@secret],
                 req_options: [plug: plug]
               )

      refute detail =~ @secret
      assert detail =~ "[REDACTED]"
    end

    test "this module logs nothing itself, so a caller owns every notification log line" do
      log =
        capture_log(fn ->
          HTTP.post(@url, %{"text" => @secret},
            sensitive_values: [@secret],
            req_options: [adapter: failing(:timeout)]
          )
        end)

      refute log =~ @secret
      refute log =~ "Transports.HTTP"
    end

    test "scrub/2 reaches nested values and redacts short explicit secrets" do
      term = %{"a" => [@secret, %{"b" => {:tag, @secret}}]}

      assert HTTP.scrub(term, [@secret]) == %{
               "a" => ["[REDACTED]", %{"b" => {:tag, "[REDACTED]"}}]
             }

      assert HTTP.scrub("bad token: xy", ["xy"]) == "bad token: [REDACTED]"
      assert HTTP.sensitive_values(sensitive_values: ["xy", "", nil]) == ["xy"]
    end
  end

  describe "header/2" do
    test "is case-insensitive and reads the first value" do
      response = %{status: 200, headers: %{"x-request-id" => ["a", "b"]}, body: ""}

      assert HTTP.header(response, "X-Request-Id") == "a"
      assert HTTP.header(response.headers, "x-request-id") == "a"
      assert HTTP.header(response, "missing") == nil
    end
  end

  describe "url_policy/0" do
    test "names a module that exports the SSRF guard" do
      policy = HTTP.url_policy()

      # `function_exported?/3` answers false for a module that is merely not
      # loaded yet, which in a lazily-loading test run is a coin flip rather than
      # a fact about the module.
      assert Code.ensure_loaded?(policy)
      assert function_exported?(policy, :validate_https_public_url, 2)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp recording_plug, do: json_plug(200, %{})

  defp json_plug(status, body, resp_headers \\ []) do
    test_pid = self()
    encoded = Jason.encode!(body)

    fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:http_request,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: request_body
         }}
      )

      resp_headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, encoded)
    end
  end

  defp failing(reason) do
    fn request -> {request, %Req.TransportError{reason: reason}} end
  end

  defp header(request, name) do
    Enum.find_value(request.headers, fn {key, value} -> if key == name, do: value end)
  end
end
