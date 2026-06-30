# Audio FX — In-Depth Guide

UncleStreamus ships with a full audio-FX chain designed specifically for
listening to live Zappa audience and soundboard tapes — material that spans 30
years, dozens of recording formats, and wildly varying source qualities.
Nothing in the chain is destructive: it all sits between the stream and your
speakers, and you can switch any of it off instantly.

This page explains what every control actually does to the sound, how to use it,
and — for the curious — a short *"Under the hood"* note on each.

> **Where to find it**
> - **macOS:** click the **FX** button; the panel replaces the setlist (the window
>   grows to fit, and restores when you close it).
> - **iOS / iPadOS:** tap **FX** to slide the panel up as a sheet; swipe it down to
>   close.

A quick mental model of the signal path, in order:

```
stream → input gain → Sub Bass → EQ → Compressor → Stereo Width/Pan → Soft Limiter → Click Guard → output
```

Everything is **smoothly ramped** when you toggle it — turning a unit on or off
fades it in or out over a fraction of a second rather than hard-cutting, so you
never get a click or a jump in level mid-song.

---

## FX Bypass & Reset All

At the top of the panel:

- **FX Bypass** — a master switch that takes the *entire* chain out of the signal
  path. Use it for an instant A/B comparison between your processed sound and the
  raw stream. Like every other control it ramps in/out smoothly rather than
  snapping.
- **Reset All** — returns every control to its default: EQ on but flat, Compressor
  off, Stereo Width at **Original**, Pan **centred**, Sub Bass off.

> **Under the hood:** there's also a fixed **−4 dB input trim** applied before
> anything else. Bootleg recordings tend to run hot and uneven; this pulls them
> back a bit leaving some headroom so EQ boosts and
> the other effects don't immediately slam the limiter.

---

## 3-Band EQ

A gentle, "musical" tone control — three bands, each ±6 dB (the Low band goes a
little further, ±8 dB). It's designed to *shape* a recording, not to surgically
fix it.

- **Low** — adds weight and body, or tightens up a boomy tape. A **low-shelf**, so
  it lifts/cuts everything below its corner rather than just one narrow spot.
- **Mid** — the presence/honk region. Boost to bring vocals and guitar forward;
  cut to tame a harsh or boxy midrange.
- **High** — air and brightness. Lifts dull audience recordings; cut to soften hiss
  or sibilance. Also a shelf.

**Using it:** drag each fader up/down. **Double-tap** any fader — or its label, or
its dB readout — to snap that band back to 0 dB. The whole EQ section has its own
on/off toggle (separate from the master bypass).

> **Under the hood:**
> - Low = 90 Hz low-shelf (±8 dB), High = 7.5 kHz high-shelf (±6 dB), both with a
>   gentle slope (S = 0.7).
> - Mid = 2.7 kHz peaking filter (±6 dB) whose **bandwidth narrows as you push it
>   harder** — small boosts are broad and natural, big boosts get more focused.
> - **iOS** faders use a relative drag at half-sensitivity (you move twice as far
>   for the same change, for fine control), with a light **haptic tick every 2 dB**.
> - **macOS** faders use absolute positioning with a square-root response, so the
>   travel near 0 dB is stretched out for precise small adjustments.

---

## Sub Bass

A small toggle to the left of the Low fader. It **synthesises** a deep low end an
octave below the bass that's actually in the recording, then mixes a subtle amount
back in. It's not an EQ boost — it adds *new* low-frequency content, so it can give
weight to thin recordings (and to small speakers/laptops) that simply have nothing
down low to boost.

**Using it:** tap to toggle on/off. It's deliberately subtle; on full-range
speakers or headphones you'll feel it more than hear it.

> **Under the hood:** the bass fundamental is isolated with a narrow band-pass
> around ~72 Hz, an envelope follower tracks its loudness, a divide-by-two stage
> generates a square wave one octave down, and two low-pass filters split that into
> a felt **fundamental (~70 Hz)** and an audible **harmonic layer (~200 Hz)** —
> the harmonics are what let small speakers *imply* the bass they can't reproduce.
> It's also partly decoupled from the Low EQ: a Low **boost** only drags the sub up
> by ~25% of its amount (so the two don't pile up), while a Low **cut** pulls it
> down fully.

---

## Compressor

Evens out the dynamics — pulls down the loud peaks so you can raise the overall
level, taming the huge swings common in live recordings (quiet intros, sudden loud
solos). A single **Gentle ↔ Heavy** slider sets how aggressive it is.

- **Gentle** — light leveling; only the peaks get touched. Good for "just smooth it
  out a bit."
- **Heavy** — firm leveling that brings quiet passages up and keeps everything at a
  consistent, forward level. Good for noisy environments or car listening.

**Using it:** flip the toggle, then set the slider. Double-tap the slider to return
to Gentle.

> **Under the hood:** the threshold is **adaptive** — instead of a fixed level, it
> continuously measures the program's average loudness (RMS) and sets itself
> relative to that, so it behaves consistently across recordings of very different
> levels. That measurement is deliberately slow and smoothed (~4.5 s) so the
> threshold drifts gently with the music rather than jumping around, and it only
> re-adjusts when the level moves meaningfully — which keeps it from "breathing."
> The meter watches the compressor's *output* (a feedback design), which tends
> toward a smoother, more forgiving response. The compression itself uses
> conventional, fairly quick envelope times: across the slider, Gentle ≈ +6 dB
> headroom / 1.5:1 ratio / ~25 ms attack / ~300 ms release; Heavy ≈ +2.25 dB /
> 8:1 / ~3 ms / ~80 ms. Make-up gain is applied automatically so turning it on
> doesn't drop your level.

---

## Stereo Width

Controls how wide the stereo image feels — from collapsed **Mono**, through the
natural **Original** width, out to **Wider** than the recording.

- **Mono** (far left) — folds both channels together. Useful for off-centre
  recordings, or single-speaker situations.
- **Original** (the marked snap point) — the recording's true stereo width,
  untouched. This is the default.
- **Wider** (right) — spreads the image for a more spacious feel.

**Using it:** drag the slider. It **snaps to "Original"** as you pass through it
(there's a small magnetic zone and a diamond marker), so it's easy to get back to
neutral; **double-tap** also returns to Original.

> **Under the hood:** widening is **frequency-dependent** — bass is kept centred and
> tight (so the low end never smears), the midrange widens modestly, and the highs
> widen the most for an airy top end (crossovers at 400 Hz and 3.5 kHz). The widest
> setting is deliberately capped a little below "maximum" to avoid an unnatural,
> phasey result. For genuinely **mono** source material it uses an all-pass-filter
> pseudo-stereo synthesis to create a believable width from a single channel rather
> than just doing nothing.

---

## Stereo Pan

Shifts the balance between left and right — **L ↔ Center ↔ R**. Handy for
recordings where the mix leans to one side, or just to nudge the image.

**Using it:** drag the slider; it **snaps to Center**, and **double-tap** recentres
it. Lives with the Stereo Width controls and shares their on/off toggle.

> **Under the hood:** it's a **constant-power** pan (sine/cosine law), so panning
> off-centre doesn't make the overall level dip the way a naïve balance control
> would.

---

## Automatic protection (always on)

Two safety effects run at the end of the chain with no controls — you don't need to
think about them, but it's worth knowing they're there:

- **Soft Limiter** — a transparent ceiling that catches anything pushed too loud
  (by your EQ boosts, the sub, or a hot recording). It eases in with a soft knee
  around −1.4 dBFS and holds a hard ceiling at −1.0 dBFS, so the output never
  clips or distorts no matter how you set the other controls.
- **Click Guard** — the streams (especially OGG and FLAC) can produce a tiny
  click at the boundary between tracks or stream segments. This detects those
  glitches and silences just the offending instant (~tens of milliseconds), fading
  cleanly back in so you barely notice.

---

## Per-show FX memory & auto-reset

By default the app **remembers your FX settings per show**. Dial in EQ, compression
and width for a particular recording, and the next time that same show comes around
on the stream your settings are recalled automatically. Snapshots are stored on the
device and mirrored via iCloud (when iCloud Sync is on), so they follow you across
your Apple devices and survive a restart.

If a show has **no** saved snapshot, the FX **reset to defaults** when that show
starts — so one recording's heavy compression doesn't carry over and surprise you
on the next.

You can change this behaviour in **Settings**:

- **Remember FX per show** (default **on**) — the per-show memory described above.
- **Keep FX across shows** — instead leave your FX settings untouched when the show
  changes. (Only available when per-show memory is off.)

---

## Quick gesture reference

| Gesture | Effect |
|---|---|
| **Double-tap** a fader / slider | Reset that control to its default |
| **Double-tap** an EQ band label or dB readout | Reset that EQ band to 0 dB |
| **Drag through** the Stereo Width or Pan marker | Snaps to Original / Center |
| **Drag** an EQ fader (iOS) | Half-sensitivity for fine control; haptic tick every 2 dB |
| **FX Bypass** toggle | Instantly A/B the whole chain vs. the raw stream |
| **Reset All** | Return every control to defaults |


