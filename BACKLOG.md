# Cuety — Backlog

Current open work. The September polish pass is archived in `POLISH_PLAN.md`; the
engineering audit of 2026-09-26 is implemented except where noted here.

## Needs measurement before any change

- **Drum and display animation cost (audit C08).** Profile repeatable GO sequences in a
  Release build with normal, Performance and Reduce Motion settings before caching
  endpoint measurements or changing the effect. No Metal/Canvas/`drawingGroup` rewrite
  without demonstrated improvement and visual parity.
- **Activity log cadence (audit C07).** Row snapshots now key on entry changes and the
  inspected JSON is cached per entry; measure before lowering the ~45 Hz counter cadence.
- **Cue tree merging at scale (audit C06).** Carryover and detail application are now
  single-pass; benchmark nested shows of 1,000 / 5,000 / 10,000 cues with many visited
  cues (edits, deletes, nested membership) for main-thread time and allocations.

## Protocol limitation (documented, not solved)

- QLab replies echo only the request path. When a timed-out request's answer is still
  owed, the next reply on that path may be either answer. Cue details treat such a reply
  as unconfirmed and ask again after the timeout window; playhead, cue-list and heartbeat
  replies do not, and rely on QLab's update stream and the next refresh.

## Cleanup still to decide

- `cuety-icon-2.icon`: archive only after confirming it is not in the target's resources
  (the group is filesystem-synchronized, so a missing project reference proves nothing).
- iOS no-op platform wrappers in `DockBadge.swift` and `FullScreenPresentation.swift`
  (optional; not a performance item).
- Pointer hiding is duplicated with Viewtiful; a candidate for optional platform support,
  not the Foundation-only `ShowControlCore`.

## Release verification

None of this is covered by the test suite:

- Real QLab routes, including delayed and missing replies and event-buffer overflow.
- Large nested shows.
- Physical iPad: lifecycle (Control Center, lock/unlock, backgrounding, multiple scenes),
  idle timer while *Keep the display awake* is on, and that startup no longer probes a
  local server.
- Mac focus changes, Settings windows and minimising: no stale label, no reconnect.
- Long and alphanumeric cue identifiers at narrow window widths, in both font designs.
- VoiceOver: drawer handle adjustment and value, cue rows.
- A show-length soak.
- The signing of the artifact actually distributed (see README).
