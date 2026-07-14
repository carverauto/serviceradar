# Contributing to inotify-rs

Thank you for considering to work on inotify-rs. We're always happy to see outside contributions, small or large.

You probably found this document in the repository of either the [inotify] or [inotify-sys] crate. Both are part of the same project, so this guide is valid for both (in fact, the documents in either repository should be identical).

## Opening issues

If you found a problem with inotify-rs, please open an issue to let us know. If you're not sure whether you found a problem or not, just open an issue anyway. We'd rather close a few invalid issues than miss real problems.

Issues are tracked on GitHub, in the repository for the respective crate:
- [Open an inotify issue](https://github.com/inotify-rs/inotify/issues/new)
- [Open an inotify-sys issue](https://github.com/inotify-rs/inotify-sys/issues/new)

If you're unsure where to open your issue, just open it in the [inotify] repository.

## Contributing changes

If you want to make a change to the inotify-rs code, please open a pull request on the respective repository. The best way to open a pull request is usually to just push a branch to your fork, and click the button that should appear near the top of your fork's GitHub page.

If you're having any problems with completing your change, feel free to open a pull request anyway and ask any questions there. We're happy to help with getting changes across the finish line.

## Commit guidelines

We use [clog] to generate a changelog for each release. This is done automatically, using the commit messages as a data source. Therefore it is very important to write clear commit messages and tag them in a way that the tool can understand.

The rest of this section explains the rules for commit messages. Please don't be put off, if this seems overwhelming. As always, if you're unsure about anything, just send a pull request. [GitCop] and the reviewer will happily point out any problems.

Before we go into the rules, here's an example of a commit message:
```
feat: Implement a feature

This is the commit message body. It is optional and might consist of
multiple paragraphs.

Here's the message body's second paragraph. The next paragraph is going
to automatically close an issue, once the commit is merged into the
repository.

Closes #123456.
```

First, let's start with the first line, the header. It's the most important part of the commit, as it's used by [clog] to generate the changelog. For that reason, it's the most heavily regulated part:
- The header's purpose is to concisely summarize the changes made.
- It must be **at most 50 characters** long.
- It should be written in the **imperative voice**, as if you're commanding someone. So, "Add something", as opposed to "Adding something" or "Added something".
- It must begin with the type of commit, followed by a colon (e.g. "feat:" or "fix:"). The following types can be used:
  - **feat**: New functionality, or changes (not bug fixes) to existing functionality.
  - **fix**: Bug fixes
  - **docs**: Improvements to documentation
  - **style**: Code formatting, indentation, etc.
  - **refactor**: Changes to code that don't change what it does. Cleaning up, moving stuff around, etc.
  - **perf**: Performance improvements
  - **test**: Changes to test code
  - **chore**: Custodial work that isn't directly related to the code. Changes to the build system, etc.

These rules apply to the message body:
- The messages body is optional, but should be added if the header and the commit diff by themselves don't explain why the commit is necessary.
- It should **provide context** for the commit and **explain its reasoning**. It doesn't need to restate things that are already obvious from the commit diff.
- Please be mindful of explanations of how the code works. Often, it makes more sense to add such explanations to the code itself, as comments.
- The length limit for lines in the commit body is **72 characters**.
- If any issues should be closed once the commit is merged, this can be done automatically by adding something like "Closes #123456" to the commit. Be careful about not doing this accidentally.

That's it! If anything about this document is unclear, feel free to open an issue. If you have questions regarding a pull request that you're working on, just open the pull request and ask your questions there.

[inotify]: https://github.com/inotify-rs/inotify
[inotify-sys]: https://github.com/inotify-rs/inotify-sys
[clog]: https://crates.io/crates/clog-cli
[GitCop]: https://gitcop.com/
