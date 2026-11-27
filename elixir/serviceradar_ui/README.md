# ServiceRadar UI

Phoenix function components, shell pieces, server-rendered SVG charts
and a prebuilt LiveView hook bundle for ServiceRadar applications.

The package targets Phoenix `~> 1.8` and LiveView `~> 1.1` (tested on
1.1 and 1.2). Rendered HTML has no `style` attributes, inline scripts
or `on*` handlers, so a page can ship it under:

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'
```

Version 0.1.0 is not on hex.pm yet. Hex package names are permanent, so
the first publish waits for maintainer approval. Until the
`serviceradar_ui-v0.1.0` tag exists, depend on the path or the git tree:

```elixir
{:serviceradar_ui, path: "../serviceradar_ui"}
```

```elixir
{:serviceradar_ui, github: "carverauto/serviceradar", sparse: "elixir/serviceradar_ui", ref: "staging"}
```

## CSS

```css
@import "../../deps/serviceradar_ui/priv/css/tokens.css";
@import "../../deps/serviceradar_ui/priv/css/components.css";
```

`tokens.css` is the `sr-*` palette (the same values web-ng uses).
`components.css` is the generic `sr-ui-*`, `sr-chart-*` and `sr-map-*`
rules. Import tokens first.

Tailwind has to see the component class names:

```css
@source "../../deps/serviceradar_ui/lib";
```

`icon/1` renders a Heroicons `hero-*` class. Keep the Heroicons plugin
your Phoenix application already generates. The package does not ship
the icon font or the Tailwind plugin.

## Components

```elixir
use ServiceRadarUI
```

imports `ServiceRadarUI.Components`, `ServiceRadarUI.Shell`,
`ServiceRadarUI.Charts` and `ServiceRadarUI.Maps`. Import one module
when a name collides with your own `CoreComponents`.

Every component takes a `:global` `rest` attribute. Pass `class` to add
classes. Branding and navigation in the shell are slots:

```heex
<.skip_link />
<.top_bar>
  <:brand>Acme</:brand>
  <:nav><a href="/devices">Devices</a></:nav>
  <:actions><.theme_toggle /></:actions>
</.top_bar>
<main id="main" tabindex="-1">
  <.button>Save</.button>
</main>
<.footer>
  <:leading>Acme</:leading>
</.footer>
```

Form errors go through an optional translator. Nothing in the package
depends on Gettext. Without a translator, `%{key}` placeholders are
interpolated:

```elixir
config :serviceradar_ui, :error_translator, {MyAppWeb.CoreComponents, :translate_error}
```

## Hooks and static files

Serve the package static files and the CSS from your endpoint:

```elixir
plug Plug.Static,
  at: "/serviceradar_ui",
  from: {:serviceradar_ui, "priv/static"},
  only: ~w(serviceradar_ui.js serviceradar_ui.js.map theme_init.js world-110m.json)

plug Plug.Static,
  at: "/serviceradar_ui/css",
  from: {:serviceradar_ui, "priv/css"},
  only: ~w(tokens.css components.css)
```

Load the theme script before paint. The storage key is `sr:theme`.
Set `data-sr-theme-key` on the script tag to use another key. There is
no inline script.

```html
<script src="/serviceradar_ui/theme_init.js" data-sr-theme-key="sr:theme"></script>
```

Register the hooks from the prebuilt ESM bundle:

```javascript
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as srHooks} from "/serviceradar_ui/serviceradar_ui.js"

const liveSocket = new LiveSocket("/live", Socket, {hooks: {...srHooks}})
liveSocket.connect()
```

`SrSparkline` and `SrTimeseries` take time zone and format through
`data-timezone`, `data-time-format` and `data-locale` (or the matching
component attributes). They do not read an application `user_time`
module.

`SrWorldMap` draws points, regions and arcs from `data-*` JSON. Push a
later update with `ServiceRadarUI.push_update/3`. The hook fetches
`/serviceradar_ui/world-110m.json` once from your origin. It does not
call a tile server. `phx-update="ignore"` is on the SVG only, so
LiveView can still patch the figure's data attributes.

`SrDialog` opens the native `<dialog>` used by `modal/1`.

## Example

`example/` is a small Phoenix application that renders every component
and hook under the strict CSP above. It is not part of the hex package.

```sh
cd example
mix deps.get
mix test
mix phx.server
```

## Development

From this directory:

```sh
mix test
mix format --check-formatted
mix credo --strict
./scripts/check.sh
```

`./scripts/test_matrix.sh` runs the suite on LiveView 1.2 (`mix.lock`)
and LiveView 1.1 (`mix.lv11.lock`, deps and `_build` under `_matrix/`).
`./scripts/check.sh` also checks formatting, warnings as errors, Credo,
the hook unit tests, the committed JS bundle, and the example app.

Rebuild the hook bundle after editing `assets/js`:

```sh
cd assets
bun install --frozen-lockfile
node scripts/build.mjs
node scripts/bundle_size.mjs
```

`node scripts/build.mjs --check` fails when `priv/static/serviceradar_ui.js`
or its source map differs from a fresh build. Commit both files.
`node_modules`, `_build`, `deps` and `_matrix` stay untracked.

Tag `serviceradar_ui-vX.Y.Z` (matching `@version` in `mix.exs`) to run
`.github/workflows/serviceradar-ui-publish.yml`. That workflow is the
only publish path. Do not run `mix hex.publish` by hand.

## License

Apache-2.0. See `LICENSE` and `NOTICE` for the bundled ISC d3 and
topojson packages and the public-domain Natural Earth data.
