# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2025-03-04

- Add support for `defmt` ([#25][])
- Fix heapless-byte feature flag ([#26][])
- Improve compiled binary size ([#23][])

[#26]: https://github.com/trussed-dev/iso7816/pull/26
[#25]: https://github.com/trussed-dev/iso7816/pull/25
[#23]: https://github.com/trussed-dev/iso7816/pull/23

## [0.1.3] - 2024-10-18

- CommandView: Precise lifetime of data ([#22][])

[#22]: https://github.com/trussed-dev/iso7816/pull/22

## [0.1.2]

- Improve `CommandView` API ([#12][])
- Add a command builder API ([#13][])
- Add support for all status bytes ([#17][])
- Improve stack usage in `CommandView::to_owned` ([#20][])

[#12]: https://github.com/trussed-dev/iso7816/pull/12
[#13]: https://github.com/trussed-dev/iso7816/pull/13
[#17]: https://github.com/trussed-dev/iso7816/pull/17
[#20]: https://github.com/trussed-dev/iso7816/pull/20

## [0.1.1] - 2022-08-22
- various fixes @robin-nitrokey @sosthene-nitrokey

## [0.1.0] - 2022-03-05

- use 2021 edition
- non-alpha release to bump dependees
- add an experimental CommandView

[Unreleased]: https://github.com/trussed-dev/iso7816/compare/0.1.2...HEAD
[0.1.2]: https://github.com/trussed-dev/iso7816/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/trussed-dev/iso7816/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/trussed-dev/iso7816/releases/tag/0.1.0
