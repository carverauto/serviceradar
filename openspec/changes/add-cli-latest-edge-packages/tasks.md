## 1. CLI package resolution

- [x] 1.1 `edge install leaf` and `edge install collector` download the matching asset from the latest GitHub release when `--version` is omitted.
- [x] 1.2 An explicit `--version` still pins the asset. `edge install agent` still requires `--version`.

## 2. Local leaf before collectors

- [x] 2.1 Leaf install confirms `serviceradar-nats` is active after `setup.sh`.
- [x] 2.2 Collector install waits for that active service before applying a bundle when the collector is bound to an edge site.

## 3. Collector target URL

- [x] 3.1 Edge-site collector bundles with a blank `nats_leaf_url` use the `tls://` client URL derived from `local_listen`.
- [x] 3.2 Edge-site JSON includes `local_listen` and `client_url` on the existing `settings.edge.manage` routes.
