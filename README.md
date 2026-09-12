<h1 align="center">Sesame</h1>

<h3 align="center">Face unlock for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Open sesame. Look at your Mac and it unlocks. Everything runs on-device with Vision and Core ML, so
your face data and your password never leave the machine. The UI lives in the notch.

A fork of [jonnyoo/glance](https://github.com/jonnyoo/glance) by Jonathan Zhou. See [FORK.md](FORK.md)
for what was changed and why, including the bugs that stopped the original unlocking anything.

---

> [!WARNING]
> ## Sesame is not as secure as Touch ID
>
> MacBooks have no depth sensor. An iPhone builds a 3D map of your face; a MacBook webcam sees a flat
> 2D image. That means:
>
> - it defeats a printed photo and a photo on a phone screen with reasonable confidence, when heavy
>   liveness detection is on
> - it does **not** reliably defeat a video of you
> - macOS gives third-party apps no way to authorize a login, so it unlocks by typing your stored
>   password at the lock screen
>
> This is a convenience feature, not a security upgrade. Only use it if you accept that trade.

## Permissions

| Permission | Why |
|---|---|
| **Camera** | To see your face. Frames are processed in memory and never written to disk. |
| **Accessibility** | To type your password into the lock screen. |
| **Touch ID** | Gates the key that encrypts your face data and password. |

## How it works

1. Onboarding captures your face from nine directions. Each frame becomes a 512-number *embedding*
   and the image is thrown away.
2. You enter your Mac password once. It is encrypted behind Touch ID.
3. When the Mac locks or wakes, the notch starts looking for a face.
4. If it is you, and the liveness checks agree you are a real person, Sesame types the password.

The threshold it matches against is measured from your own enrollment rather than hardcoded. See
[FORK.md](FORK.md#why-it-never-unlocked).

## Where is it?

Nowhere. Sesame keeps no menu bar icon and no Dock tile, and only appears in the notch while
scanning. To open Settings:

| | |
|---|---|
| `⌃⌥⌘S` | Global shortcut, works over full-screen apps |
| Open Sesame again | From Spotlight, Finder or Launchpad |
| `open sesame://settings` | For Shortcuts, Raycast or a shell alias |

## Diagnosing a failed unlock

```bash
log show --predicate 'subsystem == "app.sesame.unlock"' --last 15m --info --debug
```

Every gate that can stop an unlock says so there, with the similarity scores it measured. No
password bytes, embeddings or frames are ever logged.

## Building

Requires macOS 15+ and Xcode 26+. The Mac must be registered once in the signing team's developer
account, because the Touch ID-gated keychain items need the `keychain-access-groups` entitlement and
so a provisioning profile.

```bash
xcodebuild -project Sesame.xcodeproj -scheme Sesame -configuration Release \
  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates build
```

## Acknowledgements

- **[glance](https://github.com/jonnyoo/glance)** by Jonathan Zhou, which this is a fork of.
- **[The Boring Notch](https://github.com/TheBoredTeam/boring.notch)** for the notch window physics.
- **[InsightFace](https://github.com/deepinsight/insightface)** for the ArcFace recognition model.

## License

[MIT](LICENSE) © Jonathan Zhou
