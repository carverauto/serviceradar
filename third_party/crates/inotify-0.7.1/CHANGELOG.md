<a name="v0.7.1"></a>
### v0.7.1 (2020-06-05)

- backport: Avoid using `inotify_init1` ([#146])

[#146]: https://github.com/hannobraun/inotify/pull/146


<a name="v0.7.0"></a>
### v0.7.0 (2019-02-09)

#### Features

* Make stream API more flexible in regards to buffers ([ea3e7a394bf34a6ccce4f2136c0991fe7e8f1f42](ea3e7a394bf34a6ccce4f2136c0991fe7e8f1f42)) (breaking change)

<a name="v0.6.1"></a>
### v0.6.1 (2018-08-28)


#### Bug Fixes

*   Don't return spurious filenames ([2f37560f](2f37560f))



<a name="v0.6.0"></a>
## v0.6.0 (2018-08-16)


#### Features

*   Handle closing of inotify instance better ([824160fe](824160fe))
*   Implement `EventStream` using `mio` ([ba4cb8c7](ba4cb8c7))



<a name="v0.5.1"></a>
### v0.5.1 (2018-02-27)

#### Features

*   Add future-based async API ([569e65a7](569e65a7), closes [#49](49))



