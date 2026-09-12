<h1 align="center">Sesame</h1>

<h3 align="center">Face unlock for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Open sesame. Lift the lid, look at your Mac, and it unlocks. Everything runs on-device with Vision
and Core ML, so your face data and your password never leave the machine.

<p align="center">
  <a href="https://github.com/archit-suryawanshi/Sesame/releases/latest/download/Sesame.dmg"><b>Download for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/archit-suryawanshi/Sesame/releases/latest">Release notes</a>
</p>

Signed with Developer ID and notarized by Apple. Requires macOS 15 or later. Read the warning below
before installing: this is a convenience feature, not a security upgrade.

---

## Built on Glance

Sesame is a fork of **[jonnyoo/glance](https://github.com/jonnyoo/glance)** by Jonathan Zhou. The
camera pipeline, the notch UI, the encrypted credential store, the liveness architecture and the
guided enrollment are all his work, and they are good work: this fork changes a few hundred lines out
of fourteen thousand. If you want the original, go there. It is well built and clearly documented,
and reading it is what made every change below possible.

Face recognition on a webcam is tuning-heavy, and tuning that holds on one Mac in one room does not
always hold on another. This fork came out of one setup where unlocks were not landing, and the
changes below are what that turned into: each one measured on the hardware in front of it rather than
adjusted by feel. Your mileage on different hardware may genuinely differ.

## What this fork changes

### Thresholds measured, not fixed

`tools/embedding_bench.swift` runs the app's own detect → align → embed path over labelled face
pairs. On studio-quality portraits:

| measure | genuine | impostor |
|---|---|---|
| pairwise cosine | 0.570 … 0.818 | −0.072 … 0.016 |
| gallery top-3 mean | 0.611 … 0.793 | −0.064 … 0.083 |
| gallery centroid | 0.659 … 0.871 | −0.071 … 0.091 |

The two populations are separated by half the scale, which leaves a lot of room to put a cutoff in.
Near the top of the genuine range, a clean frontal probe is rejected about one time in six even on
good photos, and a lock-screen webcam is dimmer, lower-resolution and off-angle, which moves genuine
scores down while leaving impostors where they are.

Sesame puts the cutoff in the middle of that gap instead, decides on the mean of the three closest
samples, and keeps the centroid as a slackened sanity check rather than a second equal gate — two
independent measurements each having to clear a bar is two independent chances to miss. Most of all,
it **measures the threshold from your own enrollment** rather than shipping one number for everyone.
Verified at 6/6 genuine accepted and 0/10 impostors across every threshold from 0.30 to 0.58.

### Anti-spoofing tuned against real skin

The glare cue exists to tell skin from a screen: skin gives many small scattered specular points,
glass gives one big flat blob. Sesame treats that concentration as a gate rather than a discount, so
scattered highlights contribute nothing — a forehead lit by the lock screen's own wallpaper clears a
surprisingly low bar otherwise.

The self-test fixture for "skin" mattered here: at a very low specular fraction it was milder than
real skin under a bright display, so a tuning could pass every test and still be too eager in
practice. There is now a fixture matching a real face at a lock screen, verified to fail on the
previous formula and pass on the current one.

### A diagnosable unlock path

Everything that decides an unlock happens while the screen is locked, where no window is visible.
Sesame logs the whole path to `os_log` at `notice` and above, so entries persist and `log show` can
read them back afterwards. Scores, thresholds, gate names and reasons — never password bytes,
embeddings or frames. Every gate that can decline a scan says so by name.

It also acts on the result of typing the password and then polls the session to confirm the screen
really unlocked, because `CGEvent.post` cannot report being dropped and a scan that looks successful
is worse than one that admits it failed.

### Armed without being asked

The Touch ID session key lives only in memory and is unwrapped once per launch, so every start of the
app begins with it locked. That gate is right — a rebooted Mac should not face-unlock until a human
has touched the sensor once — but with no menu bar item there is nowhere for it to surface. Sesame
asks for Touch ID once at launch instead. Still required, still once per launch, cancelling still
leaves it locked.

### Typing that lands

The macOS lock screen can be showing the clock rather than an accepting password field, and a
password burst posted into that state loses characters with nothing visibly rejected. Sesame clicks
the field awake at the *start* of a scan, so the settling happens while the camera is still warming
rather than after a face has already been recognised.

### Faster

`AVCaptureSession.startRunning` dominates time-to-unlock. The capture session now starts the instant
a lock or wake arrives, in parallel with the settle and arm delays rather than after them, and
releases again if the scan is then declined. Those delays are shorter too. A successful unlock logs
how long recognition actually took, so the remaining budget is measurable.

### Two lock states

A Mac gets locked in two quite different situations, and treating them the same is wrong.

- **Lid opened** is an unambiguous "I am coming back to this machine". Scans automatically.
- **Locked with the lid already open** — a manual lock, an Apple-menu sleep, a display timeout — may
  be a Mac sitting in front of someone who deliberately locked it, with the owner still in frame. A
  camera that hunts for a face every time there is both wrong and unnerving, and it makes "lock my
  screen" mean nothing. This state waits for **right Shift**.

### Attention awareness

"Require attention", as Face ID means it. Your face being pointed at the Mac is not enough; your eyes
have to be on it. This is what stops a sleeping, distracted or unwilling person's face being used to
unlock the machine in front of them.

macOS has no gaze API — ARKit's `lookAtPoint` needs a TrueDepth camera, which no Mac has — so gaze is
estimated from where each pupil sits inside its eye opening, projected onto the *face's* axes so a
tilted head does not read as a sideways glance. The vertical tolerance is deliberately asymmetric:
the camera sits above the screen, so looking *at* the screen always means looking somewhat down.

It is coarse by nature. It reliably separates looking at the screen from looking well off to one
side, and does not pretend to know where on the screen you are looking.

### Out of the way

No menu bar icon, no Dock tile. Settings opens with `⌃⌥⌘S`, by launching Sesame again from Spotlight,
or with `open sesame://settings`.

### Smaller things

- The enrollment quality label counts upward now. `0/18 low` means *zero bad samples out of
  eighteen*, which is a good result that reads like a score of zero.
- Sparkle's update feed is removed, so a local build cannot offer to replace itself with the upstream
  release.
- One change was reverted rather than kept: switching `FaceAligner` to the nose tip instead of the
  nose contour's centroid looked like an obvious accuracy win, and the bench measured no benefit
  (genuine mean 0.6827 against 0.6864). It is documented in [FORK.md](FORK.md) as a dead end.

Full detail, with the measurements behind each one, is in **[FORK.md](FORK.md)**.

---

> [!WARNING]
> ## Sesame is not as secure as Touch ID
>
> This is inherited from Glance and it is still true. MacBooks have no depth sensor. An iPhone builds
> a 3D map of your face; a MacBook webcam sees a flat 2D image. So:
>
> - it defeats a printed photo and a photo on a phone screen with reasonable confidence
> - it does **not** reliably defeat a video of you
> - macOS gives third-party apps no way to authorize a login, so it unlocks by **typing your stored
>   password** at the lock screen
>
> Your password is stored encrypted behind Touch ID, and anything that fools the camera types it.
> This is a convenience feature, not a security upgrade. Only use it if you accept that trade.

## Permissions

| Permission | Why |
|---|---|
| **Camera** | To see your face. Frames are processed in memory and never written to disk. |
| **Accessibility** | To type your password into the lock screen. |
| **Touch ID** | Gates the key that encrypts your face data and password. |

## Building

Requires macOS 15+ and Xcode 26+.

1. **Set your own signing team.** `DEVELOPMENT_TEAM` in the project is the author's. Change it to
   yours, or set it in Xcode's Signing & Capabilities tab.
2. **Register your Mac** in that developer account once. The Touch ID-gated keychain items need the
   `keychain-access-groups` entitlement and therefore a provisioning profile. Xcode registers the
   machine itself on the first GUI build.

```bash
xcodebuild -project Sesame.xcodeproj -scheme Sesame -configuration Release \
  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates build
```

## Diagnosing a failed unlock

```bash
/usr/bin/log show --predicate 'subsystem == "app.sesame.unlock"' --last 15m
```

Note the `/usr/bin/` prefix: in zsh, `log` is a shell builtin and silently does something else. Add
`log stream --level debug` while locking the screen to see per-frame similarity scores.

## Tests

```bash
# Liveness decision model, on synthetic cue data
swiftc -O -o /tmp/liveness_selftest tools/liveness_selftest.swift Sesame/Liveness/*.swift && /tmp/liveness_selftest

# Attention geometry, on synthetic eyes
swiftc -O -o /tmp/attention_selftest tools/attention_selftest.swift \
  Sesame/AttentionDetector.swift Sesame/FaceDetector.swift Sesame/Liveness/*.swift && /tmp/attention_selftest
```

`tools/bench/README.md` covers the embedding benchmark, including where to get the labelled images.

## Acknowledgements

- **[glance](https://github.com/jonnyoo/glance)** by Jonathan Zhou, which this is a fork of and which
  is the great majority of this code.
- **[The Boring Notch](https://github.com/TheBoredTeam/boring.notch)** for the notch window physics.
- **[InsightFace](https://github.com/deepinsight/insightface)** for the ArcFace recognition model.

## License

[MIT](LICENSE), © Jonathan Zhou for the original work and © Archit Suryawanshi for the changes.

The bundled ArcFace model (`w600k_mbf`) is **not** covered by that MIT license. It comes from
InsightFace, whose pretrained models are published for non-commercial research use only. If that
does not suit your use, delete `Sesame/Models/ArcFace.mlpackage` and rebuild it from the official
weights with `tools/convert_arcface.py`.
