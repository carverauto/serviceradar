defmodule ServiceRadarWebNGWeb.Components.PrefixTagChips do
  @moduledoc """
  Shared prefix-tag chip rendering for flow listing, detail, and preview UIs.
  """
  use ServiceRadarWebNGWeb, :html

  @default_wrapper "mt-0.5 flex flex-wrap gap-0.5"
  @default_badge "inline-flex items-center rounded-full border border-sr-line-strong bg-transparent px-1.5 text-[0.65rem] font-semibold font-mono text-sr-ink"

  @doc """
  Normalize a raw tags field into a compact unique list of non-empty strings.
  """
  @spec normalize_tags(term(), non_neg_integer()) :: [String.t()]
  def normalize_tags(tags, take \\ 4)

  def normalize_tags(list, take) when is_list(list) and is_integer(take) do
    list
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> then(fn tags -> if take > 0, do: Enum.take(tags, take), else: tags end)
  end

  def normalize_tags(_, _), do: []

  attr(:tags, :list, default: [])
  attr(:wrapper_class, :string, default: @default_wrapper)
  attr(:badge_class, :string, default: @default_badge)

  @doc "Static badges (detail modal / preview) — no filter links."
  def static(assigns) do
    ~H"""
    <div :if={@tags != []} class={@wrapper_class}>
      <span
        :for={tag <- @tags}
        class={@badge_class}
        title={"Prefix tag: #{tag}"}
      >
        {tag}
      </span>
    </div>
    """
  end

  attr(:items, :list, default: [])
  attr(:wrapper_class, :string, default: @default_wrapper)
  attr(:badge_class, :string, default: @default_badge <> " hover:badge-primary")

  @doc """
  Linked chips. `items` is a list of `%{tag: binary, path: binary}` maps.
  """
  def linked(assigns) do
    ~H"""
    <div :if={@items != []} class={@wrapper_class}>
      <.link
        :for={item <- @items}
        patch={item.path}
        class={@badge_class}
        title={"Filter flows with tag #{item.tag}"}
      >
        {item.tag}
      </.link>
    </div>
    """
  end
end
