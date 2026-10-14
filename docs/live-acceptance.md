# Live acceptance checklist

Things only a person with the real hardware/permissions can verify. Synthetic verifiers
(`Scripts/verify.sh`) cover viddeo's own media behavior but do not satisfy these.

## M1 / M2 (record, auto-zoom) — carry-over
- [ ] Record a clip with clicks in each display corner, idle a few seconds, Stop, Export; check
      durations, sidecar positions and framing; repeat on a second display if available.
- [ ] Denied Screen Recording / Input Monitoring: UI explains, raw capture still behaves.
- [ ] A second capture after Stop works.
- [ ] Event-clock latency: clicks line up with the click frame within a frame or two.

## M3 (audio, click rings)
- [ ] Enable System Audio + Microphone, play a sound while speaking and clicking, Stop, Export:
      two audio tracks present, start aligned with video (sync by ear and by waveform).
- [ ] Microphone permission denied → clear message, export still works without mic.
- [ ] Change/unplug the input device mid-recording → recording finishes, track is not corrupt.
- [ ] Click rings: compare against Screen Studio with the circle effect enabled on the same
      scripted clicks — size growth, opacity curve, rim, three-slot behavior (and with ≥4
      clicks inside one second). Record the original clip and place it next to viddeo's with
      `./Scripts/compare-clips.sh`.
- [ ] Original defaults: confirm in Screen Studio that click effect is off and click sound is
      none by default (static source says null/null; effective runtime values unverified).

## M4 (export, comparison)
- [ ] Export one recording at each tier (web-low … studio) and both codecs; open in QuickTime
      and a browser; GIF plays and loops.
- [ ] Side-by-side original-vs-viddeo clip for the same scripted session (original must be
      recorded by hand; export it at 1080p/60/social-media for a fair bitrate match).

## Phase 5 (added as areas land)
- [ ] Captions: first run installs the Speech model for the locale (needs network once) and
      prompts for speech permission if required; check caption timing against the audio.
- [ ] Webcam: camera permission, device switching, sync with screen.

## Expanded editor / capture checklist — 2026-10-14

- [ ] Stop/load a session; split, trim, reorder, change speed/gains, undo/redo, save,
  reopen and compare the edited MP4/GIF. Confirm unsaved changes affect export.
- [ ] Enable a gradient/padding/radius and captions; compare the exported result at
  both widescreen and portrait presets. Processed preview is not yet implemented.
- [ ] Record microphone speech, generate on-device captions in a supported locale,
  correct text, regenerate, undo and save/reload; confirm cue timing and quality.
- [ ] Analyze microphone silence, apply trim/4× speed, inspect boundaries and export sync.
- [ ] Record with Smooth rendered cursor on, move/click in every display corner and
  remain still at start. Verify cursor placement, smoothing/press scale and zoom alignment.
- [ ] Opt into Hide cursor while typing; type at least three keys within 1.8 seconds,
  then move the pointer. Verify hide/reveal and timing-only session metadata.
- [ ] Deny Input Monitoring; confirm capture uses an embedded cursor when the tap cannot
  start. Interrupt monitoring after capture begins and inspect the reported warning.
- [ ] Open a legacy session and confirm its embedded cursor is not drawn a second time.
- [ ] Check quit/session switching saves edits; a failed save must keep the current editor.

## Audio mix — 2026-10-14

- [ ] Record speech with some background noise; export with Microphone cleanup Voice, Noise
  reduction and Podcast and listen: speech intelligible, no pumping or musical-noise artifacts, no
  clipping. (DSP is viddeo's own chain; synthetic tones only prove level, pitch and timing.)
- [ ] Pick a click sound, record several clicks, export and compare click audio timing against the
  visible click; the click track must be a separate third track in QuickTime/ffprobe.
- [ ] Mute system/microphone and change master volume; confirm exported tracks follow.

Camera integration remains pending; the existing camera/audio checklist
above is for their standalone modules and subsequent live integration acceptance.
