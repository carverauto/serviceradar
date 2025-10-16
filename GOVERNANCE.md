# ServiceRadar Governance

## Overview

ServiceRadar is an open-source project dedicated to providing a comprehensive monitoring and observability platform. This document describes how the project is governed and how to participate.

## Maintainers

ServiceRadar is maintained by a group of individuals who are responsible for the project's technical direction and health. Maintainers have write access to the project's repositories and are expected to review and merge contributions.

### Current Maintainers

The current list of maintainers can be found in the [CODEOWNERS](CODEOWNERS) file.

The current maintainer are:
*   [@mfreeman451](https://github.com/mfreeman451)
*   [@marvin-hansen](https://github.com/marvin-hansen)

### Becoming a Maintainer

New maintainers are added based on their contributions to the project. Contributions can include code, documentation, community management, and other forms of support. The existing maintainers will nominate and vote on new maintainers.

## Decision Making

Decisions in the ServiceRadar project are made by consensus among the maintainers. If consensus cannot be reached, the maintainers will vote.

### Voting

For a vote to pass, it must receive a simple majority of the votes from the maintainers. Votes are cast on a pull request or an issue. The voting period is 72 hours.

## Release Process and Versioning

The ServiceRadar project follows a release process that is automated using GitHub Actions. The versioning strategy is based on the `VERSION` file in the root of the repository.

### Versioning

The version is stored in the `VERSION` file and follows the format `v*` (e.g., `v1.0.53-pre14`). Pre-release strings are handled for RPM packages.

### Release Process

A GitHub Actions workflow, defined in `.github/workflows/release.yml`, is triggered by tags that follow the `v*` convention. The release process includes the following steps:

1.  **Tagging**: A maintainer pushes a new tag to the repository. The `scripts/cut-release.sh` script can be used to automate this process.
2.  **Build and Publish**: The GitHub Actions workflow builds and publishes the container images to GHCR and the Debian/RPM packages to a GitHub release.
3.  **Verification**: The workflow verifies that the release was successful.

For more details on the release process, please refer to the [RELEASE.md](RELEASE.md) file.

## Communication

The ServiceRadar project uses the following channels for communication:

*   **Community Discord**: Join our [community Discord](https://discord.gg/JhhH7wqS) to chat with other users and contributors.
*   **GitHub Discussions**: For questions and discussions, please use [GitHub Discussions](https://github.com/carverauto/serviceradar/discussions).
*   **GitHub Issues**: To report bugs and request features, please open an [issue](https://github.com/carverauto/serviceradar/issues).

## Contributing

We welcome contributions from everyone. To get started, please read our [CONTRIBUTING.md](CONTRIBUTING.md) file, which outlines the process for submitting pull requests and other contributions.

## Code of Conduct

All participants in the ServiceRadar community are expected to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). This ensures that our community is a welcoming and inclusive environment for everyone.

## Licensing

ServiceRadar is licensed under the Apache 2.0 License. All contributions to the project must be compatible with this license.
