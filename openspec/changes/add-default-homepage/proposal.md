# Change: Configurable default homepage

## Why

After sign-in, every user lands on `/dashboard`. People who live in the dashboard list, or on one dashboard, have to navigate there on every session. A group of users who share the same starting page, including users created by an identity provider, cannot be given that start without each person setting it.

## What Changes

- A user can set a homepage on `/settings/profile`: the platform home, the dashboards list, one dashboard they can open, or inherit.
- A user group can set the same kind of homepage on `/settings/user-groups`. Setting it does not share the dashboard.
- Sign-in uses the user's choice, then the most recently assigned group homepage, then `/dashboard`.
- A page the browser already asked for wins. An unsafe return path stays on `/dashboard` and does not consult the homepage.
- A stored dashboard that is gone, unpublished, or not openable by that user falls through, and the sign-in flash says so once.
- SSO applies group membership on the same request before the redirect. SAML does not invent a return path of `/dashboard`.

## Impact

- Affected specs: new capability `default-homepage`. The flows dashboard at `/flows` is unchanged.
- Affected code: `Identity.User`, `Identity.UserGroup`, `Identity.Homepage`, web-ng profile and user-group settings, `UserAuth.log_in_user`, SAML login params.
- Migration `20261005140000` adds nullable `homepage_kind` and `homepage_target` on `platform.ng_users` and `platform.user_groups`, with a check constraint. Helm `core.migrations.expectedVersion` is `20261005140000`.
