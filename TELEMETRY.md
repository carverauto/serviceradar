# ServiceRadar Telemetry Policy

This document outlines the telemetry data collection policy for the ServiceRadar project. 
## Overview

ServiceRadar collects anonymous telemetry data to help us understand how the project is used and to improve it. We believe that this data is essential for making informed decisions about the project's future direction. At the same time, we respect our users' privacy and provide the ability to opt-out of telemetry collection.

## What We Collect

ServiceRadar collects the following anonymous data:

*   **Version Information**: The version of ServiceRadar being used.
*   **Operating System**: The operating system on which ServiceRadar is running (e.g., Linux, macOS, Windows).
*   **Architecture**: The CPU architecture (e.g., amd64, arm64).
*   **Feature Usage**: Anonymized data about which features of ServiceRadar are being used.
*   **Performance Metrics**: Anonymized performance metrics, such as the time it takes to complete certain operations.

We do **not** collect any personally identifiable information (PII), such as IP addresses, hostnames, or usernames.

## How We Use It

The telemetry data we collect is used for the following purposes:

*   **To improve the project**: By understanding how ServiceRadar is used, we can prioritize feature development and make improvements that will benefit the most users.
*   **To identify and fix bugs**: Telemetry data can help us identify and fix bugs more quickly.
*   **To make decisions about the project's future**: The data we collect helps us make informed decisions about the project's future direction.

## How to Opt-Out

You can opt-out of telemetry collection by setting the `SERVICERADAR_TELEMETRY_DISABLED` environment variable to `1` or `true`.

For example:

```bash
export SERVICERADAR_TELEMETRY_DISABLED=1
```

Alternatively, you can disable telemetry in the ServiceRadar configuration file by setting `telemetry_enabled` to `false`.

## Data Ownership and Management

The telemetry data collected by ServiceRadar is owned and managed by the ServiceRadar project. The data is stored in a secure, project-managed database. The data is not shared with any third parties.

## Our Commitment to Privacy

We are committed to protecting our users' privacy. We will never collect any personally identifiable information without your explicit consent. We will always be transparent about what data we collect and how we use it.

If you have any questions or concerns about our telemetry policy, please open an issue on our [GitHub repository](https://github.com/carverauto/serviceradar).
