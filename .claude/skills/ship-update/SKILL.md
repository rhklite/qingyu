---
name: ship-update
description: Cut and publish a 轻语 (Qingyu) release so existing installs are offered it — bumps the version, rebuilds the DMG, regenerates the signed Sparkle appcast, and creates the GitHub release carrying both. Use when asked to ship, release, publish, cut a new version, push an update, make a new DMG, or get a fix out to users.
---

# Ship a 轻语 update

Users update through Sparkle. The running app reads `SUFeedURL` —
`https://github.com/rhklite/qingyu/releases/latest/download/appcast.xml` — so an update
is only real when **all** of these are true:

1. The new build's `CFBundleVersion` is **higher** than the one users are running.
   Sparkle compares this, not the marketing version.
2. `appcast.xml` is an asset on the release marked **latest**.
3. The appcast's `<enclosure url>` points at a DMG that actually exists at that URL.
4. The appcast carries an `edSignature` made with the EdDSA private key in the
   maintainer's login Keychain. Without it every install silently refuses the update.

`publish.sh` in this directory does all four in one pass and verifies each one. Prefer it
over running `scripts/release.sh` and `gh release create` by hand — the failure mode of
doing it by hand is a release nobody is offered, or one everybody is offered and nobody
can install.

## Procedure

1. **Commit the change being shipped first.** The DMG is built from the working tree but
   the tag names a commit, so `--publish` refuses to run while anything other than
   `Resources/Info.plist` is uncommitted — including untracked files.

2. **Dry run first.** This builds and verifies everything locally, publishes nothing, and
   restores `Resources/Info.plist` on the way out:

   ```bash
   .claude/skills/ship-update/publish.sh
   ```

   It takes a few minutes — the universal build is the slow part.

3. **Confirm with the user before publishing.** Creating a release is public and hard to
   take back. Show them the version it will cut and ask for the release notes. The notes
   become the text in the update window, so write them for a user, not for git.

4. **Publish:**

   ```bash
   .claude/skills/ship-update/publish.sh --publish --notes "Closing Settings now saves your changes."
   ```

   This commits the version bump, pushes it, creates the tagged release with the DMG and
   the appcast, and then re-reads the live feed to confirm it serves the new version and
   that the DMG URL resolves.

5. **Report the release URL** and tell the user their installed copy will be offered the
   update from the menu bar's "Check for Updates…" (or automatically within a day).

## Flags

| Flag | Meaning |
| --- | --- |
| *(none)* | Build and verify locally. Nothing is committed, pushed or published. |
| `--publish` | Actually ship it. Requires `--notes`. |
| `--version X.Y.Z` | Override the version. Default is a patch bump of the current one. |
| `--notes "…"` | Release notes; shown to users in the update window. |
| `--reuse-build` | Skip the rebuild and use whatever is already in `dist/`. For re-verifying, or resuming a run whose build succeeded and whose upload did not. Refuses to publish a DMG older than the sources. |

`CFBundleVersion` is always bumped by one alongside the marketing version — it is the
number Sparkle compares.

## When something fails

- **"No Sparkle EdDSA private key in the login Keychain"** — the key is what makes an
  update installable. It cannot be regenerated: a new key means no existing install can
  ever be updated again. Stop and tell the user; do not work around it.
- **"whisper.cpp is not built"** — run `scripts/build_whisper.sh`, then retry.
- **"Release vX.Y.Z already exists"** — pick a higher `--version`. Do not delete or
  overwrite a published release; installs may already be downloading from it.
- **"the live feed still does not serve X.Y.Z"** — the release was created but is not
  marked latest, or `appcast.xml` was not attached. Check
  `gh release view vX.Y.Z --repo rhklite/qingyu`.
- **The push succeeded but the upload failed.** The version bump is already committed, so
  re-run the same command with the same `--version` and add `--reuse-build`. Passing a
  version equal to the one in `Info.plist` is understood as resuming, not an error; the
  only thing that is refused is a tag that is already published.

## Testing changes to this skill

Every edit to `publish.sh` must be re-run in dry-run mode (`publish.sh` with no flags)
before it is considered working. That path exercises the bump, the build, the appcast
generation and all of the cross-checks, including mounting the DMG to read the version
out of the app inside it — everything except the commands that touch git and GitHub.

`--reuse-build` makes the same checks run in seconds instead of minutes, which is the
practical way to iterate; finish with one no-flag run so the build path is covered too.
Worth exercising deliberately, because each of these has already caught a real bug:
tampering with `dist/appcast.xml` (length, enclosure URL, `sparkle:version`, the
signature) must fail the run, and a failed run must leave `Resources/Info.plist` back at
the version it started from.
