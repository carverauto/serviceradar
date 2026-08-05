inputs = [
  "{lib,test,config}/**/*.{ex,exs}",
  ".formatter.exs",
  "*.exs"
]

[
  inputs: inputs ++ Enum.map(inputs, &"boombox_burrito/#{&1}"),
  import_deps: [:membrane_core]
]
