# Changelog

## 1.1.0

### Changed

* Improve `OpentelemetryOban.PluginHandler` Tracer span attributes.
  The Plugin's span introduce a set of attributes prefixed with `oban.`.
  Previously, no attributes were added to the span. The new attributes are:

  * All Plugin:
    * `oban.plugin`
  * `Oban.Plugins.Cron` Plugin:
    * `oban.jobs_count`
  * `Oban.Plugins.Gossip` Plugin:
    * `oban.gossip_count`
  * `Oban.Plugins.Lifeline` Plugin:
    * `oban.discarded_count`
    * `oban.rescued_count`
  * `Oban.Plugins.Pruner` Plugin:
    * `oban.pruned_count`
  * `Oban.Pro.Plugins.DynamicCron` Plugin:
    * `oban.jobs_count`
  * `Oban.Pro.Plugins.DynamicLifeline` Plugin:
    * `oban.discarded_count`
    * `oban.rescued_count`
  * `Oban.Pro.Plugins.DynamicPrioritizer` Plugin:
    * `oban.reprioritized_count`
  * `Oban.Pro.Plugins.DynamicPruner` Plugin:
    * `oban.pruned_count`
  * `Oban.Pro.Plugins.DynamicScaler` Plugin:
    * `oban.scaler.last_scaled_to`
    * `oban.scaler.last_scaled_at`

## 1.0.0

### Changed

* Publish 1.0

### Fixes

* Fix issue with insert_all

## 0.2.0-rc.5

### Changed

* Opentelemetry 1.0 support

## 0.2.0-rc.4

### Changed

* Opentelemetry 1.0.0-rc.4 support

## 0.1.0

* Initial release
