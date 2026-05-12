defmodule ServiceRadarWebNGWeb.Plugs.WebhookSignatureTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.WebhookSignature

  describe "init/1" do
    test "rejects unknown schemes" do
      assert_raise ArgumentError, ~r/:scheme must be :hex or :base64/, fn ->
        WebhookSignature.init(source_name: "x", scheme: :bogus)
      end
    end

    test "requires a source_name" do
      assert_raise KeyError, fn ->
        WebhookSignature.init([])
      end
    end

    test "accepts the expected scheme atoms" do
      assert %{scheme: :hex} = WebhookSignature.init(source_name: "x")
      assert %{scheme: :base64} = WebhookSignature.init(source_name: "x", scheme: :base64)
    end
  end

  describe "signature rejection (no matching secret)" do
    setup do
      # No DB seeded — Ash.read returns [] and the plug rejects.
      :ok
    end

    @tag :skip
    test "halts with 401 when the signature is missing" do
      # Re-enabled in the integration test suite once Ash is reachable.
      conn = run_plug(post_with_body(~s({"alert":"x"})), source_name: "falco")

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "compare_signature/3 (constant time)" do
    test "secure_compare returns true for matching signatures" do
      body = "payload"
      secret = "shared-secret"
      sig = :crypto.mac(:hmac, :sha256, secret, body)

      assert Plug.Crypto.secure_compare(sig, :crypto.mac(:hmac, :sha256, secret, body)) == true
    end

    test "secure_compare returns false for different signatures" do
      body = "payload"
      secret = "shared-secret"
      sig = :crypto.mac(:hmac, :sha256, secret, body)
      tampered = :crypto.mac(:hmac, :sha256, secret, "different-payload")

      assert Plug.Crypto.secure_compare(sig, tampered) == false
    end
  end

  ## Helpers

  defp run_plug(conn, opts) do
    WebhookSignature.call(conn, WebhookSignature.init(opts))
  end

  defp post_with_body(body) do
    :post
    |> Plug.Test.conn("/webhook", body)
    |> put_req_header("content-type", "application/json")
  end
end
