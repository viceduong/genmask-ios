# GenMask — iOS client

Public build mirror. CI runs XcodeGen + xcodebuild and uploads an unsigned
Debug `.ipa` as a workflow artifact.

GenMask is the phone-side half of a local image-editing pipeline: the app
chooses **where** an edit may act and **what** it should do, and a server on
your own machine does the rendering. Nothing is sent to a third party.

- **Automatic masking** — the host segments the subject and returns three
  apertures: clothes only, body without the head, or the whole person.
- **Manual masking** — paint the region by hand, optionally starting from an
  automatic aperture and correcting it. Brush, eraser, size, undo, clear.
- **Inpaint or full frame** — repaint only the masked pixels (everything else
  stays the photograph), or regenerate the whole image.
- Live progress over SSE with reconnect/replay, before/after compare, and save
  to Photos.

Deployment target **iOS 15.0**, so it runs on older devices. No third-party
Swift dependencies.

## Build

Push to `main`, or run the workflow manually. The artifact is `GenMask-ipa`.

Locally (needs macOS + Xcode):

```bash
cd ios && xcodegen generate --spec project.yml
xcodebuild -project GenMask.xcodeproj -scheme GenMask \
  -destination 'generic/platform=iOS' -configuration Debug clean build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Install

The `.ipa` is unsigned. Sideload it — a free Apple ID is enough:

- **Sideloadly** (Windows/macOS) — drag the `.ipa`, enter an Apple ID, install over USB.
- **AltStore** (iOS 14.5+) — needs AltServer on a computer; auto-refreshes.
- **TrollStore** (iOS 15.0–16.6.1) — direct install, no re-signing.

Expect a 7-day re-sign interval on a free Apple ID unless AltStore refreshes it.

## Configure

In **Settings**, enter the server address and its access token. The app holds no
credentials of its own and ships with none.
