defmodule ServiceRadar.Notifications.ActionLinksTest do
  @moduledoc """
  Link building is pure, so these are database-free and async.

  The load-bearing suite here is the `:stream` exemption (design D7, C2). It is
  tested three ways deliberately - the struct, the renderer options it produces,
  and an actual render - because "we pass a flag" is exactly the kind of
  invariant that survives a code review and dies to the next caller.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Notifications.Renderer

  @base "https://serviceradar.example.com"
  @delivery_id "0198f0aa-1111-7000-8000-00000000d001"
  @alert_id "0198f0aa-1111-7000-8000-00000000a001"

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp delivery(overrides \\ %{}) do
    Map.merge(%{id: @delivery_id, alert_id: @alert_id}, overrides)
  end

  defp provider(provider_type), do: %{provider_type: provider_type}

  defp build(provider_type, opts \\ []) do
    ActionLinks.build(
      delivery(),
      provider(provider_type),
      Keyword.merge([base_url: @base, now: @now], opts)
    )
  end

  describe "token-bearing destinations" do
    test "a native channel gets three capability links plus the plain deep link" do
      links = build(:native)

      assert links.links |> Map.keys() |> Enum.sort() == ~w(acknowledge alert resolve snooze)
      assert links.action_links? == true
      assert links.exempt_reason == nil
      assert length(links.minted) == 3
    end

    test "every declarative and plugin channel gets them too - no per-provider code" do
      for provider_type <- [:native, :declarative, :wasm_plugin] do
        links = build(provider_type)

        assert links.action_links?, "#{provider_type} should carry action links"
        assert length(links.minted) == 3
      end
    end

    test "each link carries its OWN capability, bound to its own action" do
      links = build(:native)

      for minted <- links.minted do
        url = Map.fetch!(links.links, Atom.to_string(minted.action))

        assert url =~ minted.token

        # And the capability behind that URL grants that action and no other.
        record = Map.put(minted.attrs, :consumed_at, nil)

        assert {:ok, :active, _record} =
                 ActionToken.verify_record(record, minted.token,
                   now: @now,
                   expect_action: minted.action,
                   expect_alert_id: @alert_id,
                   expect_delivery_id: @delivery_id
                 )
      end
    end

    test "the URL names no action and no alert, so editing it retargets nothing" do
      links = build(:native)
      acknowledge = Map.fetch!(links.links, "acknowledge")

      path = URI.parse(acknowledge).path

      assert String.starts_with?(path, "/api/notifications/actions/")
      refute path =~ "acknowledge"
      refute path =~ @alert_id
      assert URI.parse(acknowledge).query == nil
    end

    test "the deep link carries no capability" do
      links = build(:native)
      alert = Map.fetch!(links.links, "alert")

      assert alert == @base <> "/alerts/" <> @alert_id

      for minted <- links.minted do
        refute alert =~ minted.token
      end
    end

    test "the snooze capability carries the duration the label promises" do
      links = build(:native)
      snooze = Enum.find(links.minted, &(&1.action == :snooze))

      assert snooze.attrs.snooze_seconds == ActionLinks.default_snooze_seconds()
      assert snooze.attrs.snooze_seconds == 3600

      longer = build(:native, snooze_seconds: 14_400)
      assert Enum.find(longer.minted, &(&1.action == :snooze)).attrs.snooze_seconds == 14_400
    end

    test "only the digests are handed to the data layer" do
      links = build(:native)
      attrs = ActionLinks.token_attrs(links)

      assert length(attrs) == 3

      for {attr, minted} <- Enum.zip(attrs, links.minted) do
        refute inspect(attr) =~ minted.token
        assert attr.token_hash =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    test "the plaintexts are surfaced for the renderer to scrub from what it persists" do
      links = build(:native)
      sensitive = ActionLinks.sensitive_values(links)

      assert length(sensitive) == 3
      assert Enum.sort(sensitive) == links.minted |> Enum.map(& &1.token) |> Enum.sort()
    end

    test "a caller may mint a subset, and anything outside the vocabulary is dropped" do
      links = build(:native, actions: [:acknowledge, :suppress])

      assert Enum.map(links.minted, & &1.action) == [:acknowledge]
      assert links.links |> Map.keys() |> Enum.sort() == ~w(acknowledge alert)
    end
  end

  describe "the :stream provider is exempt (design D7, C2)" do
    test "no capability is minted for a broadcast" do
      links = build(:stream)

      assert links.minted == []
      assert links.action_links? == false
      assert links.exempt_reason == :stream_provider
    end

    test "the link set holds the deep link and nothing that grants anything" do
      links = build(:stream)

      assert links.links == %{"alert" => @base <> "/alerts/" <> @alert_id}
    end

    test "nothing is persisted, so a stream channel never reaches the token table" do
      links = build(:stream)

      assert ActionLinks.token_attrs(links) == []
      assert ActionLinks.sensitive_values(links) == []
    end

    test "the renderer options come from the struct, not from the caller" do
      # This is what makes the exemption survive a dispatcher that forgets to
      # pass `include_action_links?: false`: it cannot forget, because it does
      # not supply it.
      assert ActionLinks.to_renderer_opts(build(:stream)) == [
               links: %{"alert" => @base <> "/alerts/" <> @alert_id},
               include_action_links?: false
             ]

      assert [links: _links, include_action_links?: true] =
               ActionLinks.to_renderer_opts(build(:native))
    end

    test "a hand-written template cannot reintroduce a token into a broadcast" do
      stream = build(:stream)
      native = build(:native)

      template = %{
        payload_format: :json,
        subject_template: nil,
        body_template: ~s({"ack": {{ links.acknowledge | default: "" | json }}})
      }

      assert {:ok, rendered} =
               Renderer.render(
                 %{"id" => @alert_id, "title" => "t"},
                 template,
                 :json,
                 [supported_formats: [:json]] ++ ActionLinks.to_renderer_opts(stream)
               )

      assert rendered.payload["ack"] == ""

      # The same template, the same renderer, a channel that is not a broadcast:
      # the difference is the destination, not the template.
      assert {:ok, native_rendered} =
               Renderer.render(
                 %{"id" => @alert_id, "title" => "t"},
                 template,
                 :json,
                 [supported_formats: [:json]] ++ ActionLinks.to_renderer_opts(native)
               )

      assert native_rendered.payload["ack"] =~ "/api/notifications/actions/"
    end
  end

  describe "the allowlist, not a :stream denylist" do
    test "an unrecognised provider type gets no capability" do
      # The safe answer is the default. A denylist of `:stream` would silently
      # hand tokens to whatever fifth provider type is added next.
      for provider_type <- [:firehose, :unknown, nil] do
        links = build(provider_type)

        assert links.minted == []
        assert links.action_links? == false
        assert links.exempt_reason in [:stream_provider, :unknown_provider_type]
      end
    end

    test "a missing provider gets no capability" do
      links =
        ActionLinks.build(delivery(), nil, base_url: @base, now: @now)

      assert links.minted == []
      assert links.exempt_reason == :unknown_provider_type
    end

    test "the allowlist is exactly the three extensibility tiers" do
      assert ActionLinks.token_bearing_provider_types() == [:native, :declarative, :wasm_plugin]
    end
  end

  describe "nothing to bind to" do
    test "a delivery with no alert mints nothing" do
      links =
        ActionLinks.build(delivery(%{alert_id: nil}), provider(:native), base_url: @base)

      assert links.minted == []
      assert links.exempt_reason == :unbindable_delivery
      assert links.links == %{}
    end

    test "an unsaved delivery mints nothing" do
      links = ActionLinks.build(delivery(%{id: nil}), provider(:native), base_url: @base)

      assert links.minted == []
      assert links.exempt_reason == :unbindable_delivery
      # The deep link does not depend on a delivery, so it survives.
      assert links.links == %{"alert" => @base <> "/alerts/" <> @alert_id}
    end
  end

  describe "an unconfigured base URL" do
    test "renders no links at all rather than a dead relative path" do
      links = ActionLinks.build(delivery(), provider(:native), base_url: nil)

      assert links.links == %{}
      assert links.minted == []
      assert links.action_links? == false
      assert links.exempt_reason == :base_url_unconfigured
    end

    test "a blank configured value counts as unconfigured" do
      links = ActionLinks.build(delivery(), provider(:native), base_url: "   ")

      assert links.exempt_reason == :base_url_unconfigured
    end
  end

  describe "input shapes" do
    test "deliveries and providers may arrive with string keys" do
      links =
        ActionLinks.build(
          %{"id" => @delivery_id, "alert_id" => @alert_id},
          %{"provider_type" => :native},
          base_url: @base,
          now: @now
        )

      assert links.action_links?
      assert length(links.minted) == 3
    end

    test "a non-map delivery yields an empty, exempt set rather than raising" do
      assert %ActionLinks{minted: [], action_links?: false} =
               ActionLinks.build(nil, provider(:native), base_url: @base)
    end
  end
end
