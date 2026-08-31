# Ship requests

`testflight.json` is a **trigger**, not configuration. A push to `main` that
changes it starts a TestFlight build of `main`.

> ⚠️ Merging a PR that edits this file ships a build to TestFlight.

It exists because the issue routine cannot start a workflow any other way. Its
GitHub App token has Contents: write but not Actions: write, and the session it
runs in has no route to `api.github.com` at all — so both `workflow_dispatch`
and `repository_dispatch` are out of reach, whatever the token holds. A git push
is the only write primitive it has, so the trigger is a pushed file.

A human still decides every ship: the routine can only open a PR asking for one,
and the merge is what grants it.

## Fields

| Field | Meaning |
|---|---|
| `confirm` | `"ship"` builds. Anything else is a clean no-op — this is how you disarm the file without deleting it. |
| `platforms` | `both`, `ios` or `mac`. Anything else fails the run loudly. |
| `notes` | Free text, recorded in the run summary. |
| `requested_at` | Why two identical ships are still two pushes. Git needs the content to differ or there is nothing to trigger on. |
| `requested_by` | Who asked. |

## Shipping by hand

Nothing here replaces the direct route, which is still the fastest if you have a
terminal:

```bash
gh workflow run testflight.yml --repo parob/homecast --ref main \
  -f confirm=ship -f platforms=both -f notes="why"
```

Editing this file is for when you don't — a merge button works from a phone.

## Android

`play.yml` has the same unreachable-trigger problem and no ship file yet. It is
not blocking anything today; mirror this pattern when it is.
