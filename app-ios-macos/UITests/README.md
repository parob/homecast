# Reproducing iOS reports

The issue routine's Linux sandbox cannot execute iOS, but it **can ask the
`iOS Reproduction` workflow to execute the real app on a hosted Mac**. Do not
stop at “no iOS build” or send a simulator-testable report straight to
`needs-device-check`. The workflow uses XCTest UI automation, UIKit and
WKWebView, not a browser with an iPhone viewport.

## From a cloud issue run

1. Create an `ios-repro/<issue>-<description>` branch in `parob/homecast`.
   Add the reproduction to `UITests/ReproductionTests.swift` and any synthetic
   data to `UITests/Fixtures/`. The test target already compiles that file.
   For another Swift file, add it to the UI test target in the Xcode project.
2. Push **the test before the fix**. A branch push starts the workflow without
   Actions-write permissions, a dispatch API, a release, or a merge. It runs
   on pull requests too. Use an in-repository branch; fork workflows may need
   the repository owner's approval under GitHub's normal policy.
3. Read the check and its evidence artifact. It contains `environment.json`
   (device, OS, source SHA), `summary.json`, screenshots and accessibility
   trees under `attachments/`, `screen.mp4`, `xcodebuild.log`, and
   `results.xcresult`. Record the failing assertion or visually observed fault,
   exact SHA, simulator OS, and the run link on the issue before changing
   product code. A compile failure is not a reproduction of a UI fault.
4. Make the fix and push again. Run **the same scenario and assertions**;
   inspect both runs' screenshots/video. Put before/after run and evidence
   links in the PR. Keep the PR draft if the reported behavior is still
   unverified. The routine never merges or ships automatically.
5. Evidence artifacts require GitHub access and expire after 30 days. Use the
   GitHub connector's Actions/artifact capabilities where available. If that
   session cannot retrieve an artifact, link the run for review and report
   the access limitation; do not claim to have inspected it. For permanent
   inline evidence in Homecast's report UI, upload the selected non-sensitive
   screenshots/video through the existing issue-report attachment path and
   use the returned URLs in the resolution's `evidence` entries. An artifact
   download URL is not an inline image URL.

The default test is deliberately just a smoke test: launch the actual app,
send header state through the real bridge, tap native Search, receive the tap
in the page, scroll, rotate, and capture the native chrome. **It does not prove
that a particular reported defect exists or is fixed.** Add an issue-specific
assertion and scenario. For a visual defect, compare the actual captures and
describe the result; do not infer success from a green smoke test.

## Choosing the app content and OS

The default local page uses invented home data and no credentials. It is
suited to native chrome, safe areas, scrolling, rotation and bridge defects.
It does not test the production React app or HomeKit device behavior.

Optionally commit `.github/ios-repro.json` on the reproduction branch:

```json
{
  "os": "26.5",
  "only_testing": "HomecastUITests/ReproductionTests/testIssue257",
  "web_ref": "<full commit SHA in parob/homecast-web>"
}
```

All fields are optional. Omit `web_ref` to use `UITests/Fixtures`; set it to
build and serve that exact web revision. A real-web test must arrange its own
synthetic API responses/state and replace the fixture-specific smoke steps.
The test runner supplies `HOMECAST_TEST_WEB_ORIGIN` to XCTest; launch the app
with the existing Debug-only `com.homecast.devWebOrigin` preference. No release
code or production web deployment changes to enable testing.

Omit `os` to select the newest installed iOS runtime. Set it when reproducing
an OS-specific report: an unavailable runtime fails explicitly. **An iOS 27
report tested on iOS 26 is only partial evidence.** Install the required
runtime on a Mac and run locally if the hosted image does not provide it.
There is no claim that a hosted runner has every iOS release or beta.

Simulator evidence cannot establish real HomeKit pairing/accessory behavior,
ReplayKit recording, or every push/background/device-specific behavior. These
still need an appropriate device test; specify exactly what remains untested.
The production debug connector remains read-only.

## On a Mac

With Xcode and an iOS simulator runtime installed:

```bash
python3 app-ios-macos/scripts/reproduce-ios.py --output /tmp/homecast-before
# After the fix, repeat into a new directory:
python3 app-ios-macos/scripts/reproduce-ios.py --output /tmp/homecast-after
# Exact OS, test, and an optional locally built web app:
python3 app-ios-macos/scripts/reproduce-ios.py --output /tmp/homecast-issue \
  --os 26.5 --only-testing HomecastUITests/ReproductionTests/testIssue257 \
  --web-root app-web/dist
```

Every run creates and deletes its own simulator and uses its own DerivedData.
It does not erase an existing simulator, sign in to an account, or need Apple
signing credentials. Output directories must be new so evidence cannot be
silently overwritten. A filter that executes no tests is a failure.

Xcode's `.xcresult` contains the original test attachments and can be opened
in Xcode; the exported copies and recording are also directly reviewable.
See Apple's [test results documentation](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results).
