# Change: Remove SRQL search input from analytics page

## Why
The analytics page does not support SRQL search properly today, which makes the top navigation SRQL input misleading and non-functional for users.

## What Changes
- Remove the SRQL search input from the analytics page top navigation.
- Keep SRQL search available on pages where it is supported.

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng analytics layout/top navigation rendering
