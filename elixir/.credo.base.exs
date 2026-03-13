fn opts ->
  included =
    Keyword.get(opts, :included, [
      "bench/",
      "config/",
      "conformance/",
      "generated/",
      "lib/",
      "src/",
      "test/"
    ])

  excluded =
    [
      ~r"/_build/",
      ~r"/deps/",
      ~r"/node_modules/"
    ] ++ Keyword.get(opts, :excluded, [])

  %{
    configs: [
      %{
        name: "default",
        files: %{
          included: included,
          excluded: excluded
        },
        plugins: Keyword.get(opts, :plugins, []),
        requires: Keyword.get(opts, :requires, []),
        strict: Keyword.get(opts, :strict, false),
        parse_timeout: 5000,
        color: true,
        checks: %{
          disabled: Keyword.get(opts, :disabled, [])
        }
      }
    ]
  }
end
