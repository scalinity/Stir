# App Store Preview Video Script

30-second vertical video demonstrating the Stir workflow. Voice Cook Mode is the hero moment. Daniel records on physical device, edits in iMovie or CapCut, exports, uploads to App Store Connect.

---

## Deliverable specs

- **Duration:** 30 seconds max (Apple cap; anything over is rejected)
- **Orientation:** Portrait (vertical)
- **Resolution:** 1080×1920 (1080p vertical)
- **Frame rate:** 30fps or 60fps (30 preferred for smaller file + better sync on voice audio)
- **Format:** H.264 in .mov or .mp4 container
- **File size:** < 500MB
- **Audio:** Optional background music + spoken Voice Cook Mode audio at 0:18-0:22
- **Captions:** ALWAYS ON — Apple auto-plays previews muted, so captions are essential for comprehension

---

## Shot list (30s)

Frame count assumes 30fps.

### 0:00–0:03 — Hook (90 frames)

- **Visual:** Stir app icon animates in (bounce-scale from 0.8 → 1.0), then fade to Tonight Home screen
- **Caption (full-width overlay, top 1/4):** "Kitchen full. No plan."
- **Audio:** Soft musical sting

### 0:03–0:08 — Scan (150 frames)

- **Visual:**
  - Quick B-roll pan across real (anonymized) fridge interior: 1-1.5s of ingredients visible
  - Cut to Scan primer screen, camera viewfinder active
  - Cut to captured photo → Scan Review screen auto-populating with parsed ingredient chips
- **Caption:** "Point at your kitchen."
- **Audio:** Camera-shutter-like SFX on capture moment; music bed continues

### 0:08–0:13 — Solve (150 frames)

- **Visual:**
  - Constraints sheet slides up from bottom
  - Finger taps "20 minutes" chip
  - Sheet dismisses; 3 dinner cards animate in (staggered fade + rise)
- **Caption:** "3 dinners in 60 seconds."
- **Audio:** Subtle "thunk" sync per dish-card appearance

### 0:13–0:18 — Cook Mode entry (150 frames)

- **Visual:**
  - Finger taps the middle dish card ("Spinach frittata")
  - Transition to Cook Mode screen showing Step 1 of 6 with timer and ingredient list
- **Caption:** "Cook step by step."
- **Audio:** Music bed

### 0:18–0:25 — Voice hero moment (210 frames)

- **Visual:**
  - Microphone affordance pulses on-screen (Premium badge visible)
  - Voice bubble appears with transcribed user question: **"What's next?"**
  - Spoken response audio plays (real Gemini Live audio, ~3-4 seconds of content)
  - Text caption syncs to the spoken audio: **"Sauté the onions for 3 minutes."**
- **Caption (layered under spoken-text caption):** "Hands-free. Premium."
- **Audio:**
  - The actual Gemini Live response voice (prerecorded from a demo session; use a real session — don't fake it)
  - Music bed ducks -6dB during spoken audio

### 0:25–0:28 — Timer + substitution (90 frames)

- **Visual:**
  - Cook Mode screen showing a 3:00 timer running
  - Brief glimpse of Substitution Sheet sliding in with "Use Greek yogurt 1:1 for sour cream" result
  - Sheet dismisses
- **Caption:** "Timers. Substitutions. No scrolling."
- **Audio:** Music bed resumes full volume

### 0:28–0:30 — CTA (60 frames)

- **Visual:**
  - Fade to Stir logo center-screen
  - Tagline types in or fades in beneath
- **Caption (center-positioned):** "Stir — Cook what you already have."
- **Subcaption:** "7 days free on Premium"
- **Audio:** Music sting final cadence

---

## Caption style

- **Font:** Sans-serif geometric (SF Pro, Inter, or similar). Avoid serif — doesn't read at thumbnail scale.
- **Size:** 72pt at 1920-tall canvas (~3.75% of canvas height)
- **Weight:** Semibold / bold
- **Fill:** White `#FFFFFF`
- **Scrim:** 60% black rectangle behind each caption (rounded corners 8pt)
- **Position:** Bottom third of frame (to avoid being cut off by Apple's "More" banner that hovers at bottom during preview playback)
- **Timing:** Each caption enters at its shot's start and exits 12 frames (0.4s) before next caption appears

---

## Audio mix

Bed: a low-key upbeat royalty-free track (10-15 BPM slightly slower than a "commercial energy" track; Stir is a calm product, not a hyperactive pitch).

Recommended sources:
- Apple Music for Developers (direct Apple-cleared tracks): https://developer.apple.com/music-for-developers/
- Epidemic Sound / Artlist (paid — Daniel chooses)
- Kevin MacLeod (Incompetech) — free with attribution but attribution rules vary per platform

**Ducking profile:**
- Full bed during 0:00-0:18 and 0:25-0:30
- -6dB during 0:18-0:22 (voice hero) to let Gemini Live response be intelligible

**Voice Cook Mode audio:**
- Record during a real device session on the demo account. Ask the question out loud ("what's next?") after entering Cook Mode voice; the Gemini Live response is the 3-4s of spoken audio for the hero shot.
- If the Gemini response includes unwanted background context (e.g., it confirms what the user asked), trim to the first 2-3 seconds of the actual instruction ("Sauté the onions for 3 minutes...").

---

## Recording workflow (Daniel)

1. Pair physical iPhone with Mac via USB-C.
2. Open QuickTime Player > File > New Movie Recording > select iPhone as video + audio source.
3. Drive the demo account through the 7 shots sequentially. Don't worry about timing during capture — edit trims in post.
4. Record Cook Mode voice separately (cleaner audio): at Step 3, tap mic, say "what's next?", let response play, stop recording.
5. Export raw .mov from QuickTime.

---

## Editing workflow (iMovie or CapCut)

1. Import raw footage into iMovie.
2. Trim each shot to its target duration per the shot list.
3. Apply cross-dissolves (12-frame / 0.4s) between shots; cuts only on the scan-shutter and the dish-card appearance beats.
4. Layer the caption track: one text object per caption, auto-fade in/out timing per above.
5. Add music track (see Audio Mix above); apply -6dB duck between 0:18-0:22.
6. Insert Voice Cook Mode audio into the hero shot at 0:19 (1s into the shot; gives mic-tap visual a beat before voice).
7. Export at 1080×1920, 30fps, H.264 high profile, 10-12 Mbps (≤ 450MB at 30s).

---

## Quality checks before upload

- [ ] Total duration ≤ 30.0 seconds
- [ ] File size < 500MB
- [ ] All captions legible at mobile thumbnail preview (test by shrinking to 1/4 screen and checking readability)
- [ ] Stir logo + tagline readable in final CTA shot
- [ ] No debug overlays / FPS counters in any frame
- [ ] No competitor brand visibility (Instagram, TikTok, etc.) in any B-roll
- [ ] No user's personal photos / video-call thumbnails visible in any simulated Home Screen shot
- [ ] Voice Cook Mode spoken audio is intelligible
- [ ] Captions sync to audio within ±3 frames
- [ ] Music ducks cleanly during voice hero (no abrupt volume jumps)
- [ ] Exported file plays correctly on QuickTime AND Safari (Apple's upload validation is pickier than QuickTime)

---

## App Store Connect upload

- Preview Videos section of each device class (6.7" + 6.1" — same video reused)
- Poster frame: select a frame from 0:18-0:22 (voice hero moment) to use as the auto-play poster
- "App Preview" not "Screenshot Preview" in App Store Connect terminology

---

## Legal notes

- **No release forms required** — video shows no recognizable faces (use B-roll with hands-only or fridge-interior-only; no selfies or people visible).
- **Music licensing** — if using Apple Music for Developers, no attribution required in-app or in video credits. If using Epidemic Sound/Artlist, verify Apple App Store preview video is within their licensed use terms.
- **Gemini Live audio** — Google's paid-tier API policy explicitly states content is not used for model improvement; using the real response audio in the preview is fine.
- **No medical/food-safety claims** — the preview shows "Sauté the onions for 3 minutes" which is ordinary cooking guidance; avoid any claim about dietary optimization, nutrition benefits, or allergen safety that would violate the spec §19 claims-risk posture.
