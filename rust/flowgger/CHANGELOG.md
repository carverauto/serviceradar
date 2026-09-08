# Changelog

All notable changes to the time project will be documented in this file.
---


<a name="0.3.1"></a>
### 0.3.1 (2022-04-26)

#### Changes

*   Added warning if running with old time format from chrono and falling back to default one

<a name="0.3.0"></a>
### 0.3.0 (2022-03-14)

#### Breaking Changes

*   Migrate from chrono to [time](https://docs.rs/time/latest/time/)
    * String formatting changed from strftime to [time](https://docs.rs/time/latest/time/format_description/index.html) custom formatting