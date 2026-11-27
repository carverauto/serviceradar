# Used by "mix format"
[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "example/{mix,.formatter}.exs",
    "example/{config,lib,test}/**/*.{heex,ex,exs}"
  ]
]
