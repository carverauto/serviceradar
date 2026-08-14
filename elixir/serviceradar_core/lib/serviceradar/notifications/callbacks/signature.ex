defmodule ServiceRadar.Notifications.Callbacks.Signature do
  @moduledoc """
  The contract a provider's inbound callback verification implements
  (task 4.3.4, design D7).

  ## Why this is a behaviour rather than one shared function

  Task 4.3.4 originally asked for all three providers to "reuse the northbound
  stack verbatim" - a bearer token plus HMAC-SHA256 over
  `"<timestamp>.<raw_body>"` with a 300 s tolerance. That is not achievable, and
  the amendment in design.md D7 records why. In short: the northbound stack is
  token-**primary**, and Slack and Discord present no token of ours at all; each
  provider signs a different string with a different primitive; and Discord's
  Ed25519 produces no digest to compare, so the comparison function itself does
  not apply.

  What is shared is therefore the *primitives*, in
  `ServiceRadar.Notifications.Callbacks.Primitives`, not the scheme. Each
  provider implements this behaviour over them.

  ## The rule this contract exists to enforce

  A verifier's job is to fail closed. Every implementation:

    * takes the raw body as a **required argument** rather than reading it from
      somewhere that can quietly be empty. `CommandResultHandler` defaults a
      missing raw body to `""` (`raw_body/1`), and a route whose prefix is not
      registered with `RawBodyReader` supplies exactly that - so a verifier that
      inherited the default would compute a signature over the empty string and
      return an ordinary "bad signature", indistinguishable from a wrong secret.
      `Primitives.require_raw_body/2` turns that into a distinct, loud error.
    * returns a **specific** reason. The controller decides what an operator and
      the provider each get to see; a verifier that collapsed everything to
      `:invalid` would make a misconfigured secret and a replay attempt look the
      same in the logs.
    * never accepts a signature it could not parse. An unrecognised version
      prefix is `:unsupported_signature_version`, not "strip it and hope".
  """

  @typedoc """
  Everything a verifier may need to identify the request before trusting it.

  A single map rather than `(params, raw_body)` because the identifier that
  selects the key is not in the same place for every provider: Slack puts its
  `api_app_id` in the body, PagerDuty names its subscription in a header. A
  verifier that could only see params would have to be handed a doctored map to
  work, which is how a header ends up being read from the wrong place.
  """
  @type request :: %{
          required(:params) => map(),
          required(:headers) => headers(),
          required(:raw_body) => binary()
        }

  @typedoc "Lower-cased request headers, as `Plug.Conn.req_headers/0` yields them."
  @type headers :: [{String.t(), String.t()}] | %{String.t() => String.t()}

  @typedoc """
  Provider key material. A shared secret for Slack and PagerDuty; a **public**
  key for Discord, which is why this is not named `secret`.
  """
  @type key_material :: String.t()

  @type reason ::
          :raw_body_unavailable
          | :missing_signature
          | :missing_timestamp
          | :invalid_timestamp
          | :stale_timestamp
          | :unsupported_signature_version
          | :invalid_signature

  @doc """
  Verifies a provider's signature over the raw request body.

  `opts` carries `:now` so tolerance is testable without a clock.
  """
  @callback verify(raw_body :: binary(), headers(), key_material(), opts :: keyword()) ::
              :ok | {:error, reason()}

  @doc "The provider this verifier serves, for key lookup and log context."
  @callback provider_key() :: atom()

  @doc """
  Extracts what the callback needs from a provider's request body.

  Runs BEFORE verification, because the app id that selects the signing secret is
  inside the request. That is safe only because this performs no side effect: it
  reads identifiers and nothing else. The raw bytes, not this result, are what
  the signature is checked against.
  """
  @callback decode_interaction(request()) :: {:ok, map()} | {:error, atom()}

  @doc """
  Turns a decoded interaction into the capability `apply_native/2` accepts.

  Separate from `decode_interaction/2` so the controller cannot build a
  capability from an unverified interaction by accident: the two are called on
  either side of `verify/4`.
  """
  @callback capability(interaction :: map()) :: {:ok, map()} | {:error, atom()}
end
