defmodule ServiceRadarWebNGWeb.LiveViewTokenBoundaryTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Session
  alias Phoenix.LiveView.Static
  alias Phoenix.LiveView.UploadChannel
  alias Phoenix.Socket.V2.JSONSerializer
  alias ServiceRadarWebNGWeb.AuthLive.SignIn
  alias ServiceRadarWebNGWeb.Endpoint

  @moduletag :db_free

  @id "synthetic-login-view"
  @topic "lv:" <> @id
  @malformed_tokens [[], %{"value" => "synthetic-token"}, 13, 1.5, true]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:plug_crypto)
    :ok
  end

  test "accepts signed session and static tokens, including an absent static token" do
    session_token = session_token()
    static_token = Static.sign_token(Endpoint, %{id: @id, assign_new: [:current_scope]})

    assert {:ok, %Session{session: %{"locale" => "en"}, assign_new: [:current_scope]}} =
             Session.verify_session(Endpoint, @topic, session_token, static_token)

    assert {:ok, %Session{view: SignIn, assign_new: []}} =
             Session.verify_session(Endpoint, @topic, session_token, nil)
  end

  test "rejects wrong-typed session tokens decoded from LiveView join messages" do
    for token <- @malformed_tokens do
      payload = join_payload(@topic, %{"session" => token})

      assert {:error, :invalid} =
               Session.verify_session(Endpoint, @topic, payload["session"], payload["static"])
    end
  end

  test "rejects wrong-typed static tokens after a valid session token" do
    session_token = session_token()

    for token <- @malformed_tokens do
      payload = join_payload(@topic, %{"session" => session_token, "static" => token})

      assert {:error, :invalid} =
               Session.verify_session(Endpoint, @topic, payload["session"], payload["static"])
    end
  end

  test "rejects wrong-typed upload join tokens without crashing the channel" do
    socket = %Phoenix.Socket{endpoint: Endpoint}

    for token <- @malformed_tokens do
      payload = join_payload("lvu:synthetic-upload", %{"token" => token})

      assert {:error, %{reason: :invalid_token}} =
               UploadChannel.join("lvu:synthetic-upload", payload, socket)
    end
  end

  test "preserves missing, invalid, expired and wrong-topic session rejection" do
    assert {:error, :invalid} = Session.verify_session(Endpoint, @topic, nil, nil)

    assert {:error, :invalid} =
             Session.verify_session(Endpoint, @topic, "not-a-signed-token", nil)

    assert {:error, :expired} =
             Session.verify_session(Endpoint, @topic, session_token(signed_at: 0), nil)

    assert {:error, :invalid} =
             Session.verify_session(Endpoint, "lv:different-view", session_token(), nil)
  end

  defp session_token(opts \\ []) do
    Static.sign_token(
      Endpoint,
      %{
        id: @id,
        view: SignIn,
        root_view: SignIn,
        parent_pid: nil,
        root_pid: nil,
        session: %{"locale" => "en"}
      },
      opts
    )
  end

  defp join_payload(topic, payload) do
    message = Jason.encode!(["1", "1", topic, "phx_join", payload])
    JSONSerializer.decode!(message, opcode: :text).payload
  end
end
