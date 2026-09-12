# Sesame

Face unlock for a Mac. A fork of [jonnyoo/glance](https://github.com/jonnyoo/glance) that actually
unlocks.

## No menu bar item

Sesame keeps no menu bar icon and no Dock tile. It runs invisibly and only appears in the notch when
it is scanning. Three ways back into Settings replace the status item:

| | |
|---|---|
| `⌃⌥⌘S` | Global shortcut, works over full-screen apps. Registered through Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, because that route needs Accessibility and Settings is where you go to *fix* a permission problem. |
| Open Sesame again | From Spotlight, Finder or Launchpad. Launching an already-running app becomes `applicationShouldHandleReopen`, which now opens Settings instead of returning `flag` and doing nothing. |
| `open sesame://settings` | For Shortcuts, Raycast or a shell alias. |

They are listed on the About page too, since a shortcut nobody can find is the same as no shortcut.
If another app already owns `⌃⌥⌘S`, registration fails loudly in the log rather than silently, and
the other two routes still work.

Quitting Sesame turns face unlock off until it is opened again. With Settings open the app is
`.regular`, so the usual app menu and `⌘Q` are there.

## The "0 out of 18" was never a problem

Upstream labels the enrollment quality as:

```swift
"Capture quality • \(poorCount)/\(identity.samples.count) low"
```

Enrollment captures 9 poses x 2 = 18 samples, and `poorCount` counts only the ones below 0.4
quality. So **"0/18 low" means zero bad samples out of eighteen** - a flawless enrollment, not a
score of zero. The label now counts upward ("all 18 samples good") so it cannot be read backwards.

## Why it never unlocked

The match threshold shipped at 0.66, and `bestMatch` required *both* the centroid similarity and
the best single-sample similarity to clear it independently.

`tools/embedding_bench.swift` runs the app's own detect/align/embed path over labelled face pairs.
On studio-quality portraits:

| measure | genuine | impostor |
|---|---|---|
| pairwise cosine | 0.570 to 0.818 | -0.072 to 0.016 |
| gallery top-3 mean | 0.611 to 0.793 | -0.064 to 0.083 |
| gallery centroid | 0.659 to 0.871 | -0.071 to 0.091 |

The two populations are separated by roughly half the scale. 0.66 does not sit in the middle of
that gap - it sits at the very top edge of the genuine range, rejecting one clean frontal probe in
six before any webcam degradation. A lock-screen webcam is dimmer, lower-resolution and off-angle,
which pushes genuine scores down while leaving impostors where they are, so a cutoff already at the
edge on good photos rejects essentially everything in practice. It buys no security either: nothing
in the impostor population comes within 0.5 of it.

Requiring two separately-noisy measurements to *each* clear that bar compounded the problem, since
each one is an independent chance to fail an unlock that should have succeeded.

### What changed

- **Decide on the mean of the three closest samples**, not the centroid and not the single best
  sample. A max lets one lucky frame carry the decision; a top-3 mean needs the probe to agree with
  the gallery more than once, and measured out *more* conservative than the max (worst genuine 0.611
  against 0.634).
- **The centroid stays as a sanity check**, slackened by 0.12 rather than gated at the same value.
  Measured impostors never exceeded 0.091 on it, so the slack costs nothing in rejection.
- **The threshold is measured, not typed in.** `FaceMatchCalibration` scores every enrolled sample
  against the rest of the gallery (leave-one-out) and takes the worst case, minus a 0.05 margin,
  clamped to `[0.36, 0.50]`. The floor is about 3.5x the worst measured impostor collision. The
  ceiling exists because enrollment samples are all same-session and same-lighting, so a tight
  enrollment asks for a cutoff above where a real 11pm unlock lands - letting calibration chase that
  number would reproduce upstream's failure at a new value.
- **The "Match confidence" slider is now a bias** on the measured value (-0.04 / 0 / +0.05) rather
  than a raw cosine cutoff, and Settings prints the number each identity actually unlocks at.
- **Stored thresholds >= 0.56 are discarded on load.** The whole new range tops out below that, so
  any such value is from the old scale and would otherwise be carried forward forever.

Verified against the labelled set: 6/6 genuine probes accepted and 0/10 impostors at every
threshold from 0.30 to 0.58.

## A recognized face that still did not unlock

Separate bug, and the one that matches "it scanned my face once and nothing happened".

`injectStoredPassword` returned `Void`. Each of its refusal paths - Accessibility not granted, Touch
ID session locked, CGSession disagreeing about the lock state, the injection itself throwing - wrote
a reason into `statusMessage` and returned. At the lock screen nothing renders `statusMessage`, and
the caller ignored the outcome regardless:

```swift
await pocController.injectStoredPassword(requireAuthoritativeLock: true)
return .matched          // success animation, whatever actually happened
```

So a face could be recognized, the success animation could play, and the Mac would stay locked with
nothing typed. It also means the scan does *not* schedule an auto-retry, because `.matched` is the
one outcome that skips it, which is why only a single scan is seen.

Now: the injection result is returned and acted on, and after typing, the app polls CGSession for up
to 4 seconds to confirm the screen actually unlocked. `CGEvent.post` returns nothing and cannot fail
visibly, so that poll is the only place the difference is observable. A recognized face that did not
unlock reports failure and logs which of the two it was.

### Telling the last two cases apart

If the log says the password was typed but the screen stayed locked, watch the lock screen on the
next attempt:

- **the field shakes, or says the password is wrong** - the stored password is wrong. Re-enter it in
  Settings > Password.
- **nothing appears in the field at all** - the synthetic keystrokes are not reaching the login
  window. That is the approach itself failing, not a configuration problem, and the fix is to
  authenticate through PAM / a SecurityAgent plugin instead of typing.

## Face unlock silently died after every restart

The Touch ID session key lives only in `SecureCredentialManager`'s memory and is unwrapped once per
launch. Every start of the app therefore begins with the session locked, and
`FaceUnlockCoordinator.evaluateTrigger` declines to scan until something unlocks it:

```swift
guard SecureCredentialManager.isSessionUnlocked else { ... return }
```

That gate is right — it means a rebooted Mac cannot be face-unlocked until a human has touched the
sensor once. What was wrong is that nothing said so. Upstream's menu bar item read "Session Locked"
and let you fix it there. With no menu bar item, and with launch-at-login starting the app
invisibly, the Mac simply stopped face unlocking after every restart with no visible reason and
nowhere obvious to look. Nothing appears at the lock screen at all.

Sesame now asks for Touch ID once at launch, as soon as it knows a password is stored and face
unlock is on. The gate is unchanged: Touch ID is still required, still once per launch, and
cancelling still leaves the session locked. It just asks at the moment the answer is needed instead
of waiting to be found. A cancelled prompt is logged, and Settings > Password still shows the state
and an Unlock button.

## Heavy liveness had no time to work

Heavy mode requires a positive proof of life: either a blink, or more than 12 degrees of head yaw
for `poseDepthConsistency` to clear its noise floor. At a resting blink rate of roughly one every
four seconds, a 3-second scan of someone sitting still frequently contains neither, and times out as
"couldn't confirm a live face" even when recognition matched on the first frame.

The scan window is now floored at 7s under Heavy. Light imposes no floor - it only ever rejects.

The scan loop and the notch overlay also read that window from one place now. They used to read
`faceDetectionSeconds` separately, and `observeScanWindow` bails as soon as the overlay leaves
`.scanning`, so the UI collapsing could end the scan early.

## The anti-spoofing denied a real face

With recognition fixed, scans started reaching the liveness stage and being rejected there, four
times out of four, with "Screen glare detected — this looks like a photo on a display."

`glossGlare` describes itself correctly: "Skin gives many small scattered specular points; glass
gives one big flat blob." The code did not do that. Concentration was a soft discount:

```swift
let level = fractionScore * (0.3 + 0.7 * clusterFactor)
```

Perfectly scattered highlights — the exact signature of skin — still contributed 30% of full
strength. Against the 0.04 fire level that meant a real face needed only about 1.3% of its pixels
near-saturated and low-chroma to be denied as a screen, which a forehead lit by the lock screen's own
wallpaper clears without trying.

Concentration is now a gate rather than a discount, which is what the comment always claimed:

```swift
let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.5, ceiling: 0.9)
let level = fractionScore * clusterFactor
```

A face crop is 64 grid cells, so even scatter sits near 0.016 and a single blob at 1.0. Requiring
half the specular pixels in one cell is well clear of anything skin produces, and a genuine screen
reflection still denies with a wide margin.

The self-test's `skinGlare` fixture was the reason this shipped: at `specularFraction` 0.004 it was
far milder than real skin, so the tuning passed every test and then failed on a face.
`tools/liveness_selftest.swift` now also carries `brightSkinAtLockScreen` (0.03 scattered across
0.35), which fails on the old formula and passes on the new one. A denial also logs the measured
`specular`, `cluster` and `cropPx` values, so a remaining false positive is diagnosable rather than
a guess.

## Diagnosing a failed unlock

Everything that decides an unlock happens while the screen is locked, where no window is visible and
`statusMessage` is written to nobody and then overwritten. That path now logs:

```bash
/usr/bin/log show --predicate 'subsystem == "app.sesame.unlock"' --last 15m
```

Add `--debug` to include the per-frame scores. No password bytes, embeddings or frames are logged -
similarity scores, thresholds and gate names only.

Gates that used to fail silently and now say so: session locked, no password stored, face unlock
switched off, camera unavailable, Accessibility not granted, CGSession disagreeing about the lock
state, and every liveness denial with its reason.

## Changes made to build and run standalone

- **Sparkle's feed URL is removed.** Left in, a local build offers to "update" itself to the
  official release and replaces every fix here with the build that does not unlock.
- Signed under this account's team, which means the Mac must be registered in that developer
  account once (Xcode does it automatically on the first build from the GUI).

  The `keychain-access-groups` entitlement is **required**, despite `KeychainManager` never passing
  a `kSecAttrAccessGroup`. `SecAccessControlCreateWithFlags(..., .userPresence, ...)` is what forces
  it: passing `kSecAttrAccessControl` routes the item to the data protection keychain, which on
  macOS is only available to an app in a keychain access group. Without it every save fails with
  `errSecMissingEntitlement`, surfaced as "Keychain error: A required entitlement isn't present."
  at the password step. Grepping for `kSecAttrAccessGroup` and finding nothing is not enough to
  conclude the entitlement is unused.
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` on Release, so the shipped build is not debuggable by
  anything running as the user - which would otherwise be able to read the decrypted password out of
  memory.
- Bundle id `com.architsuryawanshi.sesame`, keychain service and face-store directory namespaced to
  this fork. A still-installed upstream Glance encrypts under a key this build cannot read, and
  sharing the paths turns that into an unreadable-store error rather than a clean first run.

## Rejected: the nose-tip alignment change

ArcFace's third reference point is the nose *tip*, but `FaceAligner` maps the centroid of Vision's
whole nose contour onto it, which sits noticeably higher. Changing it to the tip looked like a clear
accuracy win.

The bench measured no benefit - genuine mean 0.6827 against 0.6864 for the original, within noise.
The bias is systematic, so the similarity transform absorbs it; and picking an extremum off a noisy
contour is plausibly *less* stable frame to frame than averaging it. Reverted.

## Building

```bash
xcodebuild -project Sesame.xcodeproj -scheme Sesame -configuration Release \
  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates build
```
