# Cuety — Final Polish Plan

Tracking document for the pre-release polish pass. Derived from the source audit of
2026-09-09.

**How to use this file.** Every work item has a stable ID (`F*` audit findings, `D*` dead
code, `S*` consistency, `R*` release readiness, `V*` verification). Tick the checkboxes as
sub-steps land. Do not renumber IDs — closed items stay in place with their status so the
history stays readable. Each item states its **Done when** criterion; an item is only
closed when that criterion is demonstrably met, not when the code merely compiles.

**Priorities.** `P1` operator trust or credential exposure · `P2` functional consistency ·
`P3` cleanup and polish.

**Line references** in the *Evidence* lines were taken against the 2026-09-09 audit
checkout and have drifted in the files Phase 1 touched — `QLabClient.swift`,
`CueDisplayView.swift`, `CueDrawerView.swift`, `CueGraph.swift`, `Cue.swift`,
`DetailPill.swift`, `ActivityLog.swift`, `Preferences.swift`, `DisplaySettingsView.swift`.
Trust the named symbol, not the number.

**Landing rule.** One concern per commit, small enough to review. Phase 4's mechanical
changes must not land before `R2` (formatter configuration) is committed.

> **Broken once, deliberately recorded.** Phase 2 landed as a single commit of roughly
> 1,600 lines spanning `F7`–`F10` plus six faults found by running the app. By the time it
> was ready to land, the concerns could no longer be separated: `AppModel.refresh()` holds
> `F8`'s per-server probe ownership and the later supersession rewrite in the same few
> lines, `QLabClient.tearDownSession` holds `F8`, `F9` and the disconnect-logging fix, and
> the tests reference API from several concerns at once — so no intermediate commit would
> have built. The rule has to be followed *while* working, not retrofitted. Phase 3 onward:
> commit at each item's **Done when**, before starting the next.

---

## Progress

| Phase | Scope | Items | Done |
|---|---|---|---|
| 1 | Establish operator trust | 4 | 4 / 4 |
| 2 | Stabilize lifecycle ownership | 4 | 4 / 4 |
| 3 | Make data and Settings coherent | 4 | 0 / 4 |
| 4 | Simplify and standardize | 17 | 0 / 17 |
| 5 | Presentation and release readiness | 9 | 0 / 9 |
| — | Verification sign-off | 13 | 0 / 13 |

Phase 1's four items are implemented and covered by automated tests (182 passing).
The *visual* halves of their "Done when" criteria — a real QLab dropped mid-show, a
playhead moved by hand — belong to `V1`, `V2` and `V13` and remain open.

---

## Decisions log

Decisions that were open in the audit and are now settled. Recorded here so the rationale
does not have to be rediscovered.

| Date | Decision | Choice | Consequence |
|---|---|---|---|
| 2026-09-09 | Window model (`F7`) | Single main `Window`, not `WindowGroup` | Presentation and sidebar state become unambiguous; `model.start()` runs once; the reconnect-on-new-window fault disappears structurally. Accepts the loss of duplicate displays on multiple monitors. |
| 2026-09-09 | Drawer semantics (`F3`) | Present as a labelled cue-list neighbourhood | Keep the static traversal; correct every wording and accessibility claim. Execution/history modelling is explicitly *not* in this release — see `F3b`. |
| 2026-09-09 | Deployment target (`R8`) | Audit macOS 27-only API usage, then decide | Inventory every API that forces macOS 27 and scope the back-deployment work before committing to a floor. |
| 2026-09-09 | Cue name precedence (`F4`) | `name`, then `listName`, then nameless | QLab fills `listName` in for a cue with no name of its own — the audio file, the cue type — so it is the label the operator already recognises from QLab's window, and better than "Untitled". Recorded on `Cue.displayName`. |
| 2026-09-09 | Drawer vocabulary (`F3`) | Positional: rows above / rows below the playhead | Applies to the `Role` cases, `CueGraph`'s methods, accessibility labels and the Settings steppers. Persisted preference keys keep their original spellings so no existing setting is reset. |
| 2026-09-09 | Drawer granularity (`F3`) | A group is one row; its children are not rows | Operator's call. The drawer shows the list as QLab draws it — a group is a single line until opened — instead of expanding a four-cue show with one group into a dozen rows. `CueGraph.rows` is top-level only, but every nested cue stays indexed against its top-level row, so a playhead inside a group still has a position and the display can still name the actual cue. Boundary claims became strict, which removes a real falsehood: "End of List" no longer appears for a playhead inside the final group. |
| 2026-09-09 | Redaction layer (`F2`) | At `OSCEvent` construction, on structured arguments | Makes redaction impossible to forget rather than a rule every log surface has to remember, and lands it above the rendering that `S5` will remove. |
| 2026-09-09 | Event-buffer overflow (`F9`) | Resynchronize; escalate to a forced reconnect on a repeat | First overflow refetches cue lists, playheads and pill details and keeps the session — cheap, and invisible mid-show. A second overflow inside a short window means resynchronizing did not fix it, which points at a lapsed subscription rather than a burst, so the socket and both subscriptions get rebuilt. Never unbounded buffering. |
| 2026-09-09 | Ambiguous late replies (`F8`) | Retire the request ID on timeout; drop the late reply | A timed-out request can never be satisfied afterwards, so a delayed reply cannot be attributed to a later request for the same address. The reply is logged and discarded rather than triggering a refresh, which on a slow QLab would turn every timeout into a refresh storm. Correlating by an explicit request ID was investigated as part of this — see `F8`'s findings for whether QLab's envelope can carry one. |

### Still open

None. Both Phase 2 policy questions were settled on 2026-09-09 and are recorded in the
decisions log above.

---

## Phase 1 — Establish operator trust

Goal: every displayed cue fact has an authoritative basis, and credentials never enter
retained diagnostics.

**Phase exit criterion.** A dropped connection during presentation mode cannot leave a
stale cue on screen; the Activity Log contains no passcode in any surface; no on-screen
label asserts a playback fact it cannot know.

**Status: met in code, pending visual sign-off.** All four items are implemented and
tested (182 tests, all passing). The three criteria above are established by
`dropInvalidatesCueDataOnScreen`, `ActivityLogRedactionTests`, and the `F3` string and
label audit respectively. `V1`, `V2` and `V13` still have to be run against a real QLab
before the phase is signed off.

---

### F1 · P1 — A lost connection can leave the old cue displayed as "Standing By"

`handleSessionLost(reason:)` cancels tasks, fails pending requests, sets `status` and
schedules reconnection — but retains `workspace`, `cueLists`, `playheads` and
`watchedCueListID`. The clearing block that does reset that state belongs to
`disconnect(sendDisconnect:)` only. Both the main display and the drawer render whatever
cue data is present without first checking that the session is live, so the previous cue
survives the whole reconnect backoff. Presentation mode hides the toolbar that would
otherwise reveal the failure.

*Evidence:* `Cuety/Networking/QLabClient.swift:272` (confirmed: no cue-data reset),
`Cuety/Networking/QLabClient.swift:255` (the reset that only `disconnect` performs),
`Cuety/Features/Display/CueDisplayView.swift:15`, `Cuety/Features/Drawer/CueDrawerView.swift:15`.

- [x] Invalidate live cue data in `handleSessionLost` — clear or explicitly mark
      `cueLists`, `playheads` and `watchedCueListID` as non-authoritative.
- [x] Make the display enforce the contract independently: no cue renders unless the
      session is live. Do not rely solely on the client having cleared its state.
- [x] Apply the same rule to the drawer.
- [x] Give presentation mode a visible connection-loss state, since its toolbar is hidden.
- [x] Decide and implement what the reconnect path restores, so a successful reconnect
      repopulates the display without a manual refresh.
- [x] Regression test: seed a peer **with populated cue lists**, drop the session, assert
      no cue data is presented as live. (The existing disconnect test cannot catch this —
      see `V-gap`.)

**Done when:** with a populated show on screen in presentation mode, killing the QLab
connection replaces the cue immediately with an unambiguous loss state, and nothing
reappears until the session is genuinely re-established.

**Landed.** `invalidateLiveSessionData()` is now shared by `tearDownSession` and
`handleSessionLost`, and clears `cueLists`, `playheads`, `watchedCueListID` — plus
`isSubscribedToUpdates` and `connectedSince`, which the inspector was otherwise still
reporting as live during a dead reconnect loop. `preferredCueListID`, `workspace` and
the heartbeat history deliberately survive: they describe where Cuety was and means to
return, and the inspector labels them in the past tense. `CueDisplayView.liveCue` and
`CueDrawerView.body` each re-check `status.hasLiveData` on their own account, so the
guarantee does not depend on the networking layer having cleared anything. Presentation
mode gets `presentedStatusState` — the status glyph and title at stage scale, since
`ContentUnavailableView` is metricked for a window someone is sitting in front of.

The reconnect path restores everything it discarded and needed no new code to do so:
handshake step 7 refetches the tree and playheads, `refreshCueLists()` returns the
display to `preferredCueListID`, step 8 refills the pills. This is now asserted rather
than assumed — see `reconnectRepopulatesCueData`.

*Tests:* `dropInvalidatesCueDataOnScreen` (a populated peer with a parked playhead,
asserting all seven derived facts are gone), `reconnectRepopulatesCueData`. `V-gap` is
closed: `AuthorizationPeer` now serves cues and answers `playbackPositionID`, and
`quitPeerLeavesSessionRetrying` runs against a populated show, so its `cueLists.isEmpty`
assertion is no longer vacuous. **Outstanding:** `V1`, the visual confirmation against a
real QLab in presentation mode.

---

### F2 · P1 — Passcodes are recorded verbatim in the Activity Log

The handshake builds `/workspace/<id>/connect` with the passcode as a string argument, and
`sendAndAwaitReply` records the message into the Activity Log with its arguments unchanged.
`OSCMessage`'s argument rendering reproduces them verbatim, so the credential is visible in
the log table, in the inspector, and in copied messages. Keychain storage does not protect
this separate plaintext copy.

*Evidence:* `Cuety/Networking/QLabClient.swift:313` (connect message),
`Cuety/Networking/QLabClient.swift:553` (confirmed: logs `message` as sent),
`Cuety/OSC/OSCMessage.swift:46`.

- [x] Redact the credential **before** the retained log entry is constructed. Redacting at
      render time is not sufficient — the secret must never be stored in the log.
- [x] Cover every consumer of the entry: table row, inspector detail, and copy-to-clipboard.
- [x] Audit for any other argument that carries a secret, now or by construction.
- [x] Regression test asserting the passcode appears in neither displayed nor copied output.

**Done when:** connecting with a passcode produces a log entry showing the connect address
with a redacted argument, and the raw passcode is absent from every log surface including
copied text.

**Landed.** New `Networking/OSCRedaction.swift` owns the policy, and
`OSCEvent.init(message:direction:byteCount:timestamp:)` applies it — so redaction is not
something a call site can forget to ask for, and all three surfaces are covered by
construction rather than one at a time. The stored `arguments` string is the only form
that exists; there is deliberately nowhere to get the raw one back from.

*Audit result:* one address carries a credential — `/workspace/<id>/connect`. Every other
message Cuety sends (`/workspaces`, `/forgetMeNot`, `/udpKeepAlive`, `/alwaysReply`,
`/updates`, `/listen/playhead`, `/cueLists`, `/playbackPositionID`, `/valuesForKeys`,
`/thump`, `/disconnect`) takes no secret, and nothing inbound does either: QLab's reply
to `connect` answers with the granted tier or `badpass` and never echoes what was sent.
QLab 4's `/workspace/<id>/connect/<passcode>` address form is documented in
`carriesCredential(_:)` as the case that would need the *address* redacting too — not
implemented, because Cuety has never built that form and untested code guarding nothing
is worse than a note.

*Two deliberate non-redactions:* the byte count stays the real packet size (the
inspector's traffic totals describe the wire, not the placeholder), and a `connect` with
no arguments is left untouched rather than given a placeholder, which would claim a
passcode was used on an unprotected workspace.

*Tests:* `CuetyTests/ActivityLogRedactionTests.swift` — seven tests covering storage, the
clipboard, the byte count, every entry the log holds, the narrowness of the rule against
six non-credential messages, the argument-free `connect`, and a multi-argument `connect`
(the rule redacts every argument rather than assuming position one).

*`S5` design note:* the redaction operates on `[OSCValue]` and returns an `OSCMessage`,
before any string rendering. When `S5` moves the log to structured arguments, the same
`OSCRedaction.redacting(_:)` call stays where it is and the rendering below it goes away.

**Outstanding:** `V13`, the manual pass — connect to a passcoded workspace, then inspect
and copy from the Activity Log.

---

### F3 · P1 — The drawer claims playback facts from list position

*Decision: present as a labelled cue-list neighbourhood.*

The drawer's previous rows come from a static tree traversal, yet accessibility describes
them as "Just taken" and "cues ago". Moving the playhead without firing anything makes
those statements false. The same traversal treats every group child as an upcoming cue,
which does not reliably predict the next GO — QLab can advance past a group while its
children execute independently.

*Evidence:* `Cuety/Model/CueGraph.swift:40`, `Cuety/Features/Drawer/CueDrawerView.swift:156`,
[QLab group cues](https://reference.qlab.app/docs/v5/fundamentals/group-cues/).

- [x] Remove every wording that asserts playback history or execution order: "Just taken",
      "cues ago", "already taken", "next".
- [x] Relabel the section so it reads plainly as neighbouring rows in the cue list.
- [x] Correct the accessibility labels to match — position in list, not playback state.
- [x] Audit the main display and pills for the same class of claim.
- [x] Fix the stale "already taken" comment (tracked jointly with `S6`).

**Done when:** no drawer string or accessibility label states anything that a static list
traversal cannot know, verified by moving the playhead without firing a cue.

**Landed.** `CueRowView.Role` is now `.above(distance:)` / `.below(distance:)`, and the
accessibility labels read "1 row above the playhead" … "3 rows below the playhead" in
place of "Just taken", "cues ago", "Next" and "cues ahead". `Role.isNext` became
`isFocalRow` and `nextCueFontSize` became `largestRowFontSize`. `CueGraph.previous(before:)`
and `upcoming(after:)` became `rowsAbove(_:count:)` and `rowsBelow(_:count:)`. The
drawer's accessibility label is now "Cue list around the playhead".

`CueGraph.flatten(_:into:)`'s comment claimed depth-first order "is the order the playhead
visits them in QLab", which is exactly the false premise `F3` is about; it now states the
opposite and points at group modes. The type doc says outright that callers must not
phrase its results as playback history.

Settings said "Previous cues" and "Upcoming cues"; it now says "Rows above the playhead"
and "Rows below the playhead", with a footer explaining what the drawer shows.
`Preferences.drawerPreviousCount` / `drawerUpcomingCount` became `drawerRowsAboveCount` /
`drawerRowsBelowCount` — the *persisted keys keep their original strings* so nobody's
existing setting is reset, which is noted at both ends.

*Audit of the display and pills:* clean. Every claim they make comes from an authoritative
QLab property rather than from traversal — "Standing By" from `playbackPositionID`,
continue-mode and disarmed/flagged from the cue's own fields, the group pill from `type`.
The one traversal-derived claim is the display's "· End of List", which is `graph.isLast`
and is a truthful statement about list position.

**Groups collapsed to one row** (operator's call, 2026-09-09). `CueGraph` was rebuilt
around it: `rows` is the top-level cues only, while `cuesByID` and `rowIndexByCueID` still
index every nested cue against the top-level row containing it. So the two consumers that
need full-depth lookup keep it — `playheadCue`, and the broadcast handler working out
which list a cue belongs to — while the drawer only ever sees rows.

This closed the second half of `F3` more thoroughly than the wording changes alone did.
The audit's objection was that "the same traversal treats every group child as an upcoming
cue, which does not reliably predict the next GO". The drawer no longer shows group
children at all, so it makes no claim about them. `isFirst`/`isLast` also became strict:
a playhead inside the final group no longer makes the display print "· End of List" when
there are cues after it inside that group.

A playhead parked inside a group would otherwise leave an unlabelled rule apparently
sitting between two unrelated rows, so `playheadMarker(insideGroup:)` names the group —
"in Storm" — and exposes that to VoiceOver, since it is the one fact no row can convey.

*Tests:* new `CuetyTests/CueGraphTests.swift`, nine tests over a fixture with a group
nested inside a group: rows, neighbourhoods skipping group contents, nested cues still
findable, a doubly-nested playhead resolving to the same neighbourhood as its group, strict
boundaries, empty lists, zero counts, and clamping at both ends.

**Outstanding:** `V2`, moving the playhead by hand with nothing fired to confirm no
surviving string reads as history — now also covering stepping into and out of a group.

---

### F3b · P3 — Execution and history modelling (deferred, post-release)

Explicitly out of scope for this release per the 2026-09-09 decision. Recorded so the
deferral is deliberate rather than forgotten: truthful "just taken" and "next GO" require
tracking actually-fired cues and honouring group modes.

- [ ] Not started — revisit after release.

Note: collapsing groups to one row (see `F3`) shrinks what this would have to fix. The
drawer no longer implies anything about a group's children, so the remaining gap is
history — which cues actually fired — rather than group-mode traversal. `V3` still needs
running against real group modes to confirm nothing else depends on the old assumption.

---

### F4 · P2 — The "Cue List" pill uses the wrong QLab property

Cuety treats `cue.listName` as the containing cue list's name. QLab defines it as the
cue's displayed name *within* the list. The SwiftUI previews and the decoding fixture
repeat the same incorrect assumption, so the tests confirm the bug rather than catching it.

*Evidence:* `Cuety/Features/Display/DetailPill.swift:146` (confirmed),
`CuetyTests/QLabReplyTests.swift:180`,
[QLab OSC dictionary](https://qlab.app/docs/v5/scripting/osc-dictionary-v5/).

- [x] Derive the containing cue list from the actual graph, not from `listName`.
- [x] Reconcile `name` and `listName` when determining the cue's visible name, and
      document which wins.
- [x] Correct the decoding fixture so it encodes QLab's real semantics.
- [x] Correct the previews.
- [x] Depends on `S7` (cue-graph indexing) if list lookup proves hot.

**Done when:** the pill shows the containing list's name for a cue nested in a group, and
the fixture would fail against the old interpretation.

**Landed.** New `Array<Cue>.cueList(containing:)` finds the containing list by searching
the tree. `DetailPill` and `DetailPillsRow` now take `cueListName` explicitly, because the
cue genuinely does not carry it — `DetailPill.content(for:cue:)` gained the parameter, so
there is no overload left that could quietly read `listName` again.
`CueDisplayView.cueListName(containing:)` checks the watched list first (where the playhead
cue lives in every ordinary case) and falls back to the general search.

*Reconciliation, documented on `Cue.displayName`:* the operator's `name` wins wherever
they gave one; failing that, `listName` — which is QLab's *displayed* name for an unnamed
cue, such as the audio file it plays — because that is the label they already recognise
from QLab's own window, and it beats "Untitled". Only with neither does a cue count as
nameless.

*Fixture:* `QLabReplyTests.cueListsJSON` now spells `listName` as QLab does (each cue's own
display name), adds a second cue list and an unnamed audio cue whose `listName` is
`rain-loop.wav`. Under the old interpretation `cue-1` and `cue-2` would report their cue
lists as "House to Half" and "Thunder", so the new assertions fail against it.

*`S7`:* not needed. The lookup avoids `CueGraph` entirely and reuses the existing
`firstCue(withID:)` walk, so it adds no graph rebuilds. `D4` is therefore unaffected —
`CueGraph.cueListID` / `cueListName` are still unread and still removable.

*Tests:* `containingCueListIsDerivedFromTheTree` (top-level cue, cue nested in a group, cue
in a second list, a group reporting its list rather than itself, and an unknown ID
returning `nil` rather than defaulting), `unnamedCueUsesQLabDisplayName`. Three previews:
action cue, group cue, and a new unnamed-cue preview.

---

## Phase 2 — Stabilize lifecycle ownership

Goal: window creation, reconnects, overlapping refreshes and workspace changes cannot
revive obsolete state.

**Phase exit criterion.** No code path can resurrect a session or overwrite fresh state
with the result of an operation that has been superseded.

**Status: met, and signed off.** All four items implemented, every sub-item closed, and no
caveats outstanding; 213 tests passing. Landed as `b75a758`, verified as `14a4356`, with
`F9`'s recovery branches covered as of the commit following.

---

### F7 · P2 — Opening another main window can reconnect the shared session

*Decision: single main `Window`.*

`WindowGroup` permits multiple main windows and every window calls `model.start()`, which
starts another untracked task that refreshes discovery and eventually reconnects any active
session. Presentation state and sidebar visibility are shared across windows regardless.

*Evidence:* `Cuety/App/CuetyApp.swift:16`, `Cuety/Features/MainWindowView.swift:14`,
`Cuety/Model/AppModel.swift:104`.

- [x] Replace the main `WindowGroup` with a single `Window`.
- [x] Make `model.start()` idempotent anyway — the guarantee should not depend on the scene
      type alone.
- [x] Track the startup task so it can be cancelled, and ensure a second call cannot start
      a second one.
- [x] Confirm presentation state and sidebar visibility now have exactly one owner.
- [x] Check menu commands and any `openWindow` call sites still behave with a single window.

**Done when:** there is no user action that produces a second main window, and calling
startup twice performs the work once.

**Landed.** `Window("Cuety", id: WindowID.main.rawValue)` replaces the group, which removes
File ▸ New Window as a matter of scene type rather than by disabling a command.
`AppModel.startupTask` makes `start()` idempotent independently of that: the guard asks
"has this launched?" and the handle is never cleared on completion, so a second call after
the first has finished cannot re-run discovery and auto-connect either.

*A real fault found while wiring the cancellation up.* `autoConnectIfNeeded()` polls for ten
seconds and stands down once a workspace is selected — but `disconnect()` clears the
selection, which reads as "nothing chosen yet". Disconnecting inside the launch window was
therefore undone a second or two later by Cuety reconnecting to the workspace the operator
had just left. `disconnect()` now cancels the startup task first, and the poll checks
`Task.isCancelled` as well as the selection. This is what the tracked task is *for*, rather
than cancellability for its own sake.

*Ownership:* `isPresenting` and `sidebarVisibility` always lived on `AppModel`, which under
a `WindowGroup` meant two main windows shared one presentation state — entering stage mode
in either collapsed the sidebar in both. One window fixes it; per-window state is not what
this app wants. `openWindow` is only ever called for the two auxiliary `Window` scenes,
which were already single, and `AppCommands` contributes no window commands.

*Tests:* `CuetyTests/AppModelLifecycleTests.swift` — `startIsIdempotent`,
`disconnectCancelsAutoConnect`, `cancellationIsNotUndoneByAnotherStart`. `V8` (confirming a
second window cannot be opened) is now a property of the scene type rather than of
behaviour, but still wants a click-through.

---

### F8 · P2 — Request cancellation and refresh ownership are incomplete

The request layer installs no cancellation handler. Cancelling a debounced refresh stops
its initial sleep but does not cancel a request already being awaited. Multi-request loops
can continue running after teardown, and a global refresh can overwrite the results of a
single-server refresh (and vice versa). Separately, replies are matched by address in FIFO
order, so a delayed reply arriving after one request has timed out can satisfy a later
request to the same address.

*Evidence:* `Cuety/Networking/QLabClient.swift:536` (confirmed: continuation with no
`onCancel`; `pendingByAddress` FIFO at `:547`), `Cuety/Model/AppModel.swift:138`.

- [x] Add a cancellation handler to the request primitive so an awaited request fails
      promptly on cancellation and its bookkeeping is cleaned up.
- [x] Give every refresh operation explicit ownership — a generation token or single owning
      task — so a superseded refresh cannot mutate state.
- [x] Stop obsolete multi-request loops before their next request *and* before their next
      state mutation, not only at loop entry.
- [x] Define the recovery policy for ambiguous late replies (see **Still open**) and
      implement it; at minimum a timed-out request's ID must not be satisfiable later.
- [x] Reconcile global vs. single-server refresh so neither clobbers the other.
- [x] Tests: cancel mid-request; late reply after timeout; overlapping refreshes.

**Done when:** teardown and supersession both stop in-flight work deterministically, and a
late reply cannot be attributed to the wrong request.

**Landed.** `sendAndAwaitReply` is wrapped in `withTaskCancellationHandler`, so cancelling
a task that was awaiting a reply now fails it at once instead of leaving the continuation
suspended for the full timeout with its bookkeeping intact. The continuation body also
handles being already-cancelled before it was installed, which is the one ordering that
would otherwise never resume. The deadline is armed only if the request is still pending
after the send, which stops a leaked timeout task per cancelled request.

*Late replies — protocol finding first.* Correlating by an explicit request ID is **not
available at this protocol**: QLab's reply envelope carries `workspace_id`, `address`,
`status` and `data`, and there is nowhere to round-trip an identifier of Cuety's own. So
the agreed policy is what is implemented. A timeout retires its request ID *and* records
what QLab still owes on that correlation key; the next reply on the key is recognised as
the abandoned request's and dropped rather than handed to whatever is waiting now. The
entries expire after one request timeout, and that bound is stated honestly in
`abandonedReplyDeadlines`: if QLab never answers at all, the debt is spent on the next
request instead, costing one wasted request per genuine timeout before it ages out. Drops
are counted in `lateReplyCount` and shown in the connection inspector — a rising count
means the request timeout is shorter than this QLab needs, which is something the operator
can act on.

*Refresh ownership is per **server**, which is the level the conflict was at.* The global
refresh used to snapshot the whole server list, probe part of it, and publish the entire
snapshot at the end — overwriting fresh results for servers it had never re-asked. It now
publishes each server as its probe completes, and `probeWorkspaces(on:)` is the single
owner of probe bookkeeping: the fetch, the error capture, `hasBeenProbed`, and the
in-flight indicator, all in one place instead of written out once per caller. A
generation per server means a superseded probe publishes nothing and touches nothing.
Superseding the *whole* global refresh would have been the opposite mistake — re-asking one
machine is no reason to abandon the other five.

*Obsolete loops:* `refresh` checks `Task.isCancelled` before each probe, and
`refreshPlayheads` checks both cancellation and connection identity before each request.
The mutation half was already safe — `request` re-checks the connection after its await and
refuses to return a reply from a session that has ended — which is now stated where the
loop is. A cancelled probe no longer records "the operation was cancelled" as a *server*
error, and a cancelled `refreshPlayheads` returns instead of logging a warning per
remaining list.

*Side effects:* `D6` (`PendingRequest.id`) is removed, and the probe-consolidation half of
`S2` is done. `refreshingServerIDs` now holds only what is genuinely in flight, so the
sidebar spinner walks the list instead of appearing on machines that have not been asked
yet — the truthful rendering, and noted on the property.

*Tests:* `cancellingProbeFailsPromptly`, `cancellingSessionRequestFailsPromptly`,
`lateReplyIsNotGivenToALaterRequest` (withholds `/thump` replies past their timeout, then
releases them — the heartbeat is where identical replies on one address collide),
`skippedServersAreNotClobbered`. The test peer gained `withholdRepliesTo` /
`releaseWithheldReplies`: a QLab that is slow rather than silent.

---

### F9 · P2 — The event buffer silently drops messages despite claiming otherwise

The comment asserts that cue updates must not be lost, but the stream uses
`.bufferingNewest(512)`, which discards buffered events when full, and the result of
`yield` is ignored. This stream carries replies and connection events as well as playhead
updates, so a burst can drop a reply.

*Evidence:* `Cuety/Networking/QLabConnection.swift:70`,
[buffering policy](https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy).

- [x] Inspect the `yield` result and detect the dropped/terminated cases.
- [x] Decide the recovery policy (see **Still open**) — resynchronize or force reconnect.
      Do **not** switch to unbounded buffering.
- [x] Implement recovery, and surface the event so it is diagnosable rather than silent.
- [x] Correct the "buffer rather than drop" comment (tracked jointly with `S6`).
- [x] Test: burst enough events to overflow and assert recovery runs.

**Done when:** overflow triggers a deliberate, observable recovery and the comment matches
the code.

**Landed.** `yield` now switches on its result. `.dropped` counts the loss and reports it;
`.terminated` is deliberately not treated as an overflow, because whoever finished the
stream is already tearing the connection down. The capacity is a named constant and the
buffering stays bounded. The old comment claimed a burst "must not lose the playhead change
hiding inside it" — with `bufferingNewest` that is exactly what it does, and the comment
now says so and points at the recovery.

Reporting does not go through the stream, which is the channel that is full at the moment
the news needs to travel; it goes through a handler installed before `start()`. Reports are
coalesced into 100 ms episodes, so one burst produces one report with a total rather than
one call per lost event.

*Policy, as agreed:* first overflow resynchronizes — cue tree, playheads, then the visible
cue's details, which is `F5`'s sequence — and a second within ten seconds forces a
reconnect, on the grounds that a refetch which did not hold is the signature of a lapsed
subscription rather than a busy moment. Recovery is debounced 250 ms so it does not run
into the burst that caused it. `droppedEventCount` is shown in the connection inspector.

The choice itself is `QLabClient.recovery(after:at:)` returning `EventLossRecovery`
(`.resynchronize` / `.rebuildSession`) — pure, `nonisolated`, no socket and no clock of its
own. Extracted deliberately: the rule was three lines of instant arithmetic inside the
async method that acted on it, which made the policy unreachable except through a real
overflow. Separated, it is both a named thing and directly assertable.

**A finding worth recording: overflow needs a stalled *consumer*, not a fast producer.**
The receive loop only re-arms after handing each packet to the actor, so inbound traffic
paces itself and the buffer stays about one event deep however hard QLab pushes — a burst
of four thousand messages does not overflow it. What does overflow it is the reading side
stopping while messages keep arriving, which on a real show means the main actor held up
behind a redraw. `stalledConsumerOverflowIsReported` reproduces exactly that, and asserts
both the detection and the coalescing.

*Tests:* `CuetyTests/EventLossRecoveryTests.swift` covers the policy directly — first loss,
repeat inside the window, loss after the window, the window boundary in both directions,
two losses in one instant, and a cleared history after an escalation (the rule that makes
teardown resetting `lastOverflowRecovery` correct rather than incidental).

**Covered end to end, in two halves that meet at a seam.** A real overflow cannot be
provoked from outside `QLabClient` — it needs that class's own event consumer stalled — and
a hook that faked the trigger would only prove the hook worked. So the coverage meets in
the middle at `handleEventLoss(_:)`, which is internal rather than private for exactly
that reason:

- **Trigger → report:** `stalledConsumerOverflowIsReported` overflows a real buffer with a
  reader that genuinely stalls, and asserts the count and the coalescing.
- **Report → effect:** `firstEventLossRefetchesCueData` changes the peer's show *without
  notifying*, which is precisely what a dropped update means, then reports a loss and
  asserts the new cue appears — which can only happen if the tree was really refetched.
  `repeatEventLossRebuildsTheSession` lets the first recovery finish, reports a second loss
  inside the window, and asserts the peer sees a **new socket** — a refetch reuses the one
  it has, so only a rebuild can produce that.

Both effect tests assert observable consequences rather than that a method ran, so neither
can pass vacuously. `V7` against real QLab remains worthwhile as the only end-to-end burst,
but it is no longer the only thing standing between this policy and a regression.

---

### F10 · P2 — Connection actions follow different rules depending on their location

The sidebar permits disconnecting a reconnecting session; the Connection menu disables
Disconnect whenever live data is unavailable; the inspector applies a third condition. Menu
Refresh can run during connection setup while sidebar Refresh is disabled.

*Evidence:* `Cuety/App/AppCommands.swift:34`, `Cuety/Features/Sidebar/WorkspaceSidebar.swift:64`,
`Cuety/Features/Connection/ConnectionInspectorView.swift:84`.

- [x] Define availability in one place, expressed in terms of *session intent* rather than
      "is live data present".
- [x] Point the menu, sidebar and inspector at those single definitions.
- [x] Settle the intended behaviour for each action while reconnecting and while
      connecting, and document it.
- [x] Verify with keyboard shortcuts as well as clicks.

**Done when:** for any session state, every control offering the same action agrees on
whether it is enabled.

**Landed.** Three definitions on `AppModel`, each stated in terms of what the operator is
trying to do:

| Action | Definition | Behaviour while *connecting* | Behaviour while *reconnecting* |
|---|---|---|---|
| `canDisconnect` | `client.isSessionActive` | Available — mid-connect is a session to call off | Available |
| `canConnect` | `!client.status.isTransitional` | Blocked | Available |
| `canRefresh` | `!client.status.isTransitional` | Blocked | Available |

The common thread: `hasLiveData` answers "is there anything to show", which is not the
question. A reconnect backoff has nothing to show and is emphatically a session — so the
menu's old `hasLiveData` test greyed Disconnect out for the whole thirty-second backoff,
the one stretch in which an operator most wants it, while offering Connect for the
workspace Cuety was already trying to reach. Refresh rebuilds the session as well as
re-asking the network, so it stands down during setup; the menu used to permit it and the
sidebar's button did not.

Menu, sidebar (context menu, Refresh button, Remove Server, and the selection binding) and
inspector now all read these. The inspector's third condition — whether a workspace had
been negotiated — is gone. The sidebar keeps `isConnecting` as a re-entrancy guard for its
own async action, since a double-click can land twice before `status` becomes `connecting`,
and that is now stated as distinct from availability.

*`S2`'s other half done here:* the sidebar's `probingServerIDs` was a second copy of
`refreshingServerIDs`, and the two had drifted into showing spinners under different
conditions. It is gone; `AppModel` owns probe bookkeeping.

*Tests:* `connectionActionAvailability` (connected, then dropped and backing off),
`availabilityDuringConnectionSetup` (held in `connecting` by a mute peer), `idleAvailability`.

**Verified by the operator, 2026-09-10.** ⌘R behaves consistently with the sidebar button
in each state. `F10` closed.

---

## Phase 3 — Make data and Settings coherent

Goal: each action has immediate, truthful feedback.

**Phase exit criterion.** No state is displayed as known when it is unknown, failed, or
stale, and every Settings action visibly takes effect.

---

### F5 · P2 — Ordinary cue updates can erase the detail pills

`refreshCueLists()` replaces the complete cue tree — including previously fetched detail
values — then refreshes playheads without reloading details. QLab's `/cueLists` payload
does not contain the separately requested duration, waits, notes, and continue mode, so
those values vanish after an edit and stay absent until some other trigger fetches them.

*Evidence:* `Cuety/Networking/QLabClient.swift:782`, `Cuety/Networking/QLabClient.swift:895`,
[QLab OSC dictionary](https://qlab.app/docs/v5/scripting/osc-dictionary-v5/).

- [ ] Establish one refresh sequence: cue tree → playheads → details for the visible cue
      and its enabled pills.
- [ ] Use that sequence from every trigger — handshake, `/updates`, broadcast, manual
      refresh — so no path skips details.
- [ ] Either preserve already-fetched detail values across a tree replacement or guarantee
      they are refetched in the same sequence. State which, and why.
- [ ] Coordinate with `F8` ownership so the sequence cannot interleave with itself.
- [ ] Test: edit a cue while pills are visible; assert pills are repopulated.

**Done when:** editing a cue in QLab while the detail pills are on screen never leaves a
pill blank once the refresh settles.

---

### F6 · P2 — Missing, failed, and genuinely empty states are conflated

A failed playhead query leaves no dictionary entry, and the display describes that absence
as an unset playhead. Deleting the watched cue list leaves the stale selection intact,
because refresh only picks a list when the selection is `nil`. An unknown broadcast cue is
assigned to the watched list as a fallback even when ownership is unconfirmed.

*Evidence:* `Cuety/Networking/QLabClient.swift:810`, `Cuety/Networking/QLabClient.swift:701`,
`Cuety/Features/Display/CueDisplayView.swift:145`.

- [ ] Represent query failure explicitly, distinct from "no playhead set".
- [ ] Represent unresolved cue identity explicitly instead of defaulting to the watched
      list.
- [ ] Reconcile the watched-list selection whenever the cue-list collection changes, not
      only when the selection is `nil`.
- [ ] Give each state its own honest wording: unknown, failed, empty.
- [ ] Tests: failed playhead query; deletion of the watched list; broadcast for a cue in an
      unknown list.

**Done when:** deleting the watched list moves the display to a valid state on its own, and
a failed query never reads as an empty one.

---

### F11 · P2 — Saved-passcode behavior is not coherent

Settings reads the Keychain from a computed view property, but deleting a passcode mutates
no observable state, so the list has no guaranteed refresh after Forget. Save and delete
errors are swallowed. A successful passcode connection updates the remembered workspace
only when "Remember in my Keychain" is selected, coupling two unrelated preferences.

*Evidence:* `Cuety/Model/AppModel.swift:271`, `Cuety/Features/Settings/ConnectionSettingsView.swift:146`.

- [ ] Maintain observable credential metadata so Settings updates without a manual reload.
- [ ] Surface Keychain save/delete failures to the operator instead of discarding them.
- [ ] Record the last successful workspace independently of credential storage.
- [ ] Verify Forget takes visible effect immediately.
- [ ] Test the Keychain-failure path.

**Done when:** Forget updates the list at once, a Keychain failure is reported, and
declining to remember a passcode still remembers the workspace.

---

### F12 · P2 — Server identity and discovery rely on inconsistent assumptions

Manual identity uses the raw host string, so equivalent spellings and localhost aliases
create duplicates. Bonjour identity uses only the service name. The UI hides discovered
servers by matching names rather than verified endpoint identity. Refresh restarts
asynchronous discovery and then immediately snapshots the existing server list, so newly
discovered servers miss that refresh's workspace probes.

*Evidence:* `Cuety/Model/QLabServer.swift:46`, `Cuety/Networking/QLabBrowser.swift:156`,
`Cuety/Model/AppModel.swift:143`.

- [x] Define a canonical server identity, separate from the display name.
- [x] Normalize manual host entry into that identity, including localhost aliases.
- [x] De-duplicate the UI on identity rather than name.
- [x] Give discovery a clear lifecycle so servers found during a refresh are probed by it.
      *Was ticked in error once — see below.*
- [x] Test equivalent host spellings.
- [x] Test a server discovered mid-refresh.

**Done when:** the same server entered two ways appears once, and a server discovered
during a refresh gets its workspace probe.

### Found by running the app, 2026-09-10

Five faults from one session with QLab open locally. Four are fixed; the fifth is the
identity work still listed above.

**1. Four spurious `127.0.0.1` rows — a test-isolation hole, not a discovery bug.**
`AppModel.init` built `QLabBrowser()` against `.standard` regardless of the `Preferences`
it was handed, so injecting an isolated defaults suite isolated the preferences and nothing
the *browser* persisted. The `F10` tests added manual servers on the peer's ephemeral ports
and wrote them into the real app's sidebar, where four of them accumulated. Now
`QLabBrowser(defaults: preferences.defaults)` — one store per model — and
`Preferences.defaults` is readable for exactly that reason. The four stale entries were
deleted from the container plist.

This is worth remembering as a class of bug: partial injection reads as isolation and
isn't. Anything persisting under an `AppModel` has to take the same store.

**2. This Mac was not probed at launch.** Deliberate, and wrong. The rationale was that
probing loopback unasked "just refuses a connection every launch" — but QLab on this Mac
is the most common setup of all, so the usual outcome was the operator clicking *Check for
Workspaces* before Cuety would look at the machine it was running on, while every Bonjour
server got probed automatically. The `probingLocalhost` parameter is gone entirely, along
with the `targetIsLocalhost` special case it forced on `autoConnectIfNeeded`.

**3. Refresh was locked out for the duration of a refresh.** With four unreachable servers
probed one after another at a full request timeout each, that was a long time to stare at a
sidebar you knew was stale. `refresh()` now supersedes the pass in progress —
`refreshGeneration` keeps a superseded pass from switching the indicator off under its
replacement — and `canRefresh` no longer consults `isRefreshing`.

**4. Refresh gave no sign of touching a server that already had workspaces.** The
"Looking for workspaces…" row only renders when a server has *no* workspaces, so This Mac
showed nothing at all while being re-probed, which reads as Refresh having skipped it. The
in-flight indicator now lives in the section header, where it shows either way.

*Verified by the operator, 2026-09-10:* Refresh now visibly updates This Mac. This had
been the open question of whether the probe was genuinely being skipped as well as being
invisible — it was not. Faults 2 and 4 together account for the whole symptom.

**5. The Refresh button's spin.** Now magic-replaces between `arrow.clockwise` and
`progress.indicator`, with `.variableColor.iterative` on the latter. A slowly rotating
glyph reads as a stuck animation and says nothing about how long there is to wait.

Reached the right answer on the second try, which is worth writing down. The first attempt
swapped in a `ProgressView` with a `blurReplace` transition, on the reasoning that
`.replace.magic` is a *symbol* effect and a `ProgressView` is an `NSProgressIndicator`
with nothing to morph. True, but the wrong conclusion: `progress.indicator` **is** a
symbol, and `ConnectionStatus.connecting` was already using it with the same effect. So a
genuine morph was available all along, and taking it means "Cuety is working" now looks
identical wherever it appears instead of having two visual dialects. Reduce Motion
suppresses the effect but keeps the glyph swap.

The section-header indicator (fault 4) stays a `ProgressView` with a `blurReplace`: it
appears and disappears rather than replacing anything, and a spinner is the standard
control for that position.

*Tests:* `refreshProbesThisMac`, `refreshIsNotLockedOutByItself`. The superseded test
`skippedServersAreNotClobbered` was retired — with nothing skipped any more its premise no
longer exists.

**Manual identity — closed 2026-09-11.** `QLabServer.identity(host:port:)` is now the
canonical form, separate from `name`, which stays whatever the operator typed.

Folded away as spelling: case, surrounding whitespace, the DNS root dot, IPv6 brackets, and
every alias for this machine — `localhost`, `127.0.0.1`, `::1` and its expansions, plus
this Mac's own sharing and DNS names with or without `.local`. The port is *kept*, because
two QLab instances on one machine are genuinely two servers.

`127.0.0.1:53000` canonicalises to `localhost:53000` deliberately: that is the spelling the
built-in entry has always used and the one persisted as `lastServerID`, so an existing
remembered workspace still matches. It also means `loadManualServers`' localhost filter now
catches the junk rows it previously let through — the four stale entries could not
accumulate again.

De-duplication moved out of the display. `QLabBrowser.apply(results:)` merges on
`QLabServer.id` with manual entries winning, so one machine is one row however it was
found; `bonjourServers` no longer filters by comparing *names*, which was identity by
string match in the view layer. This Mac's own Bonjour advertisement collapses onto the
built-in entry.

**Known limit, deliberately not solved:** a *remote* machine discovered by Bonjour and also
added by hand as an IP address still appears twice. Unifying them needs address resolution,
and Cuety leaves resolution to the system at connect time on purpose. There is a test
asserting the current behaviour so the limit is visible rather than surprising.

*Tests:* `CuetyTests/ServerIdentityTests.swift`, 17 cases — nine spellings of this Mac,
case and root-dot folding, port-as-identity, distinct hosts staying distinct, name kept
separate from identity, adding `127.0.0.1` returning the existing "This Mac" row, and the
remote Bonjour-vs-manual limit.

**Discovery lifecycle — closed 2026-09-11, after being ticked in error.** This item was
marked done during Phase 2 on the strength of work that did not address it: probes gained
per-server *ownership*, which stops a superseded probe clobbering a fresher one, but
`performRefresh` still took `browser.servers` once immediately after `restartBrowsing()`.
Bonjour answers asynchronously, so a machine appearing mid-pass was never asked, and showed
"Check for Workspaces" *immediately after a refresh* — which reads as the refresh having
skipped it.

Now probed in up to `refreshDiscoveryPasses` (3) passes, each asking only what the previous
ones did not, so a server present from the start is still asked exactly once. Bounded
deliberately: the point is to catch machines found *during* the pass, not to wait for the
network to settle — that would hold the refresh indicator on, and a second press of Refresh
is the honest way to ask again.

*Test:* `serversFoundMidRefreshAreProbed`, and it was **falsified before being trusted** —
with `refreshDiscoveryPasses` temporarily set to 1 it fails, with 3 it passes. It also had
to be rewritten once: the first version added the server *before* the refresh task actually
began (`Task { }` only schedules) so it passed against the very snapshotting it was meant
to catch. It now blocks the first pass on an unroutable documentation-range address to open
a real window.

---

## Phase 4 — Simplify and standardize

Goal: one convention and one owner per responsibility, with a small reviewable diff per
concern.

**Phase exit criterion.** `R2` is committed, the dead code is gone, error handling uses
Foundation's contract, and no comment contradicts its code.

---

### F13 · P2 — Diagnostics contain misleading totals and inconsistent errors

Bundle handling attributes the whole packet's byte count to every contained message,
inflating received-byte totals. Activity totals include discovery and earlier connections
but are labelled "this session". The custom `OperatorReadableError` mechanism omits
`QLabConnection.ConnectFailure`, so its deliberately helpful timeout wording falls through
to generic text.

*Evidence:* `Cuety/Networking/QLabConnection.swift:256`,
`Cuety/Features/ActivityLog/ActivityLogView.swift:248`, `Cuety/Networking/QLabClient.swift:1068`.

- [x] Teardown's goodbye messages never reached the log at all — found by an operator
      looking for `/disconnect` and not finding it. `/forgetMeNot false`,
      `/udpKeepAlive false` and `/disconnect` called `connection.send` directly, bypassing
      the only place outbound traffic is recorded, so they were sent and acted on while the
      Activity Log — which presents itself as *every* message sent and received — showed
      nothing, and `bytesSent` was short by exactly those packets. Now routed through the
      log via `QLabClient.goodbyeMessages`. `/alwaysReply false` is deliberately not among
      them: it is per-connection state that dies with the socket, and `/forgetMeNot false`
      has already told QLab to remember nothing — the operator confirmed that call on
      2026-09-10, so the goodbye set is settled at three messages. Tests:
      `disconnectIsSentAndLogged`, `lostSessionSendsNoGoodbye`.
- [ ] Count packet bytes once for a bundle rather than per contained message.
- [ ] Label counter scope accurately, or scope the counters to match the existing label.
- [ ] Replace `OperatorReadableError` with Foundation's
      [`LocalizedError`](https://developer.apple.com/documentation/foundation/localizederror/errordescription)
      and conform every error type, including `ConnectFailure`.
- [ ] Confirm the timeout wording actually reaches the UI.

**Done when:** received-byte totals match the wire, counter labels match their contents,
and every error type's intended wording is what the operator sees.

---

### Dead code removal

Confirmed by grep during plan preparation — all eight have no call sites or reads.
Framework-required framer callbacks are **not** dead code and stay.

| ID | Item | Location | Done |
|---|---|---|---|
| D1 | `QLabConnection` convenience initializer and `targetEndpoint` | `Networking/QLabConnection.swift:52`, `:61` | [ ] |
| D2 | `OSCValue.zeroWidthTags`, `doubleValue`, `intValue`, `blobValue` | `OSC/OSCValue.swift:83`, `:101`, `:112`, `:134` | [ ] |
| D3 | `QLabServer.Source.sectionTitle` | `Model/QLabServer.swift:13` | [ ] |
| D4 | `CueGraph.cueListID` / `cueListName` — stored, never read | `Model/CueGraph.swift:17` | [ ] |
| D5 | `ActivityLog.reset()` — no call sites | `Model/ActivityLog.swift:155` | [ ] |
| D6 | `PendingRequest.id` — dictionary key already identifies the request | `Networking/QLabClient.swift:408` | [x] removed with `F8` |
| D7 | Trailing `_ = connection` no-op | `Networking/QLabClient.swift:380` | [ ] |
| D8 | Playhead reply success check — unreachable, `request()` already rejects failures | `Networking/QLabClient.swift:830` | [ ] |

> `D4`: check `F4` first. If deriving the containing list needs list identity on the graph,
> these fields become *used* rather than removed.

---

### Consistency work

The code is already broadly idiomatic — descriptive types, conventional casing, typed
errors, Observation, actors, standard controls. The standard here is Swift's
[clarity at the point of use](https://www.swift.org/documentation/api-design-guidelines/),
not forcing every function into one shape. A wholesale rewrite is explicitly out of scope.

| ID | Work | Done |
|---|---|---|
| S1 | Replace bindings that ignore their incoming value and call `toggle()` with explicit setters | [ ] |
| S2 | ~~Consolidate duplicated server-probe bookkeeping~~ (done with `F8`/`F10`; `F12`'s discovery-lifecycle half remains) and ~~connection-action availability~~ (done with `F10`) | [x] |
| S3 | Remove redundant `async` propagation where a method only schedules work synchronously | [ ] |
| S4 | Narrow internal-only helper visibility | [ ] |
| S5 | Retain structured log arguments instead of rendering to strings and re-parsing them for the inspector (pairs with `F2`) | [ ] |
| S6 | Correct stale comments: "Milestone 5", "buffer rather than drop", ~~"already taken"~~, and the claim that the cue graph rebuilds only when its inputs change | [ ] |
| S7 | Cache or index cue traversal where justified — `watchedGraph` rebuilds on every access, and broadcast handling builds extra graphs just to locate a cue | [ ] |
| S8 | Validate preferences at the boundary — the default-port field accepts invalid ports; persisted timing/count values are not normalized | [ ] |

> `S5` and `F2` must be designed together: the redaction has to survive the move to
> structured arguments, and structured arguments are what make redaction clean.
>
> Settled by `F2`. `OSCRedaction.redacting(_:)` takes and returns an `OSCMessage`, so it
> already operates on structured arguments and sits *above* the rendering. `S5` deletes
> the rendering beneath it and leaves the redaction call untouched.
>
> `S6`'s "already taken" is done — see `F3`, which also corrected a second comment of the
> same kind that the audit had not caught: `CueGraph.flatten` claiming depth-first order
> is the order the playhead visits cues in. "Milestone 5" (`QLabClient.swift:807`),
> "buffer rather than drop" (`QLabConnection.swift:73`, tracked with `F9`), and the
> cue-graph rebuild claim are still outstanding.

---

## Phase 5 — Presentation and release readiness

Goal: a reproducible build and a completed native UI checklist.

**Phase exit criterion.** The build is reproducible from a clean checkout with a shared
scheme, the app has its own identity, and the layout/accessibility pass is signed off.

---

### F14 · P2/P3 — Layout and accessibility verification pass

Source-supported risks, not yet visually reproduced. Reproduce each before fixing, so the
fix is aimed at a real failure. Prefer content-driven native layout throughout.

*Evidence:* `Cuety/Features/Display/DetailPill.swift:272`,
`Cuety/Features/Drawer/CueDrawerView.swift:218`, `Cuety/Support/Motion.swift:8`.

- [ ] Pills occupy one non-wrapping row and treat an unbounded list name as fixed-width
      content — reproduce at a narrow window with a long list name, then fix.
- [ ] The drawer allows twenty surrounding rows with no scroll or height constraint —
      reproduce at a short window, then fix.
- [ ] Number-column sizing uses a hidden `"000.0"` template that cannot fit arbitrary cue
      numbers — replace with content-driven sizing.
- [ ] Reduce Motion is honoured in the sidebar but not consistently in the main display,
      drawer, pills, or toolbar — apply it uniformly.
- [ ] Notes are reorderable in Settings although their position is ignored on screen —
      either honour the order or stop offering it.
- [ ] Run the VoiceOver and contrast audits over the display, drawer, pills and sidebar.
- [x] The sidebar's Refresh button spun its glyph slowly enough to read as a stuck
      animation — now swaps to the standard indeterminate indicator (see `F12`'s
      2026-09-10 session notes).
- [ ] **Toolbar buttons do not show the press/scale response.** Investigated at length on
      2026-09-10 and concluded **not a Cuety defect** — see below. No action pending unless
      new evidence appears.

#### Toolbar press response — investigated, parked

An operator reported that toolbar buttons never "grow a little" on click the way every
other Mac app's do. Four hypotheses were tried and all four were wrong: a `Group` of two
buttons inside one `ToolbarItemGroup` (fixed anyway — see below), `.animation(_:value:)`
clamping the press transaction out of the label's subtree, press-time observable
invalidation rebuilding the toolbar, and a design-system opt-out.

What the evidence actually shows:

- A **stock `Button` with a stock `Label` and no modifiers, in a plain `ToolbarItem`**, does
  not respond. That rules out every per-button explanation.
- All three windows are affected, including the Activity Log, which is a plain `Window`
  with no `NavigationSplitView`.
- The **system's own sidebar toggle** does not respond either, and Cuety does not create it.
- `MACOSX_DEPLOYMENT_TARGET` is `27.0` against the current SDK; there is no
  `UIDesignRequiresCompatibility` or equivalent opt-out in `MyApp/Info.plist` or the build
  settings; no app-wide `buttonStyle`; every `.animation` uses the scoped `value:` form.
- **The one toolbar control that behaves correctly is the Activity Log's segmented
  `Picker`.** That is the tell: a `Picker` draws its own control chrome, while `Button` and
  `Toggle` depend on the toolbar's glass treatment for theirs. The failure tracks exactly
  that split.
- Every app observed to behave correctly builds its toolbar with **AppKit**
  `NSToolbarItem`, not SwiftUI's `ToolbarItem`. Finder, Mail and Xcode are AppKit outright.
  CotEditor was raised as a SwiftUI counter-example and checked directly: it is a hybrid —
  `DocumentWindowController` is an `NSToolbarDelegate` serving `NSToolbarItem`s
  (`toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`), and SwiftUI appears only
  as `NSHostingView` content *inside* those items. Its toolbar buttons therefore take
  AppKit's path too.

So the dividing line is not app-by-app, it is **AppKit `NSToolbarItem` vs SwiftUI
`ToolbarItem`** — the one thing every failing control in Cuety shares and no working
example does.

That is consistent with filed reports of macOS 26+ toolbar glass problems affecting system
toolbar buttons while custom `.glassEffect()` views are unaffected, including
`NSGlassContainerView` intercepting hit-testing inside `NSToolbarView` and hit regions
smaller than the visual capsule — which is also the best available explanation for the
oddest symptom: clicking just outside a button pops the glass but does not invoke it, while
clicking the glyph invokes it without a pop. Two different responders own those two
regions.

Kept from the investigation because it is correct regardless: `ConnectionStatusIndicator`
was one `View` returning a `Group` of two `Button`s inside a single `ToolbarItemGroup`, so
the toolbar saw one item of custom content rather than two toolbar buttons. It is now
`ActivityLogButton` and `ConnectionStatusButton`, one `ToolbarItem` each.

**Options, none of them free:**

1. **Leave it and file a Feedback Assistant report.** Costs nothing, fixes nothing, and is
   the only option that does not add code. Revisit when the SDK changes.
2. **Host an AppKit `NSToolbar`** via an `NSWindow`/`NSToolbarDelegate` bridge, the way
   CotEditor does. This is the option that demonstrably works — and it means an AppKit
   window controller under a SwiftUI app for the sake of one animation. A large,
   load-bearing change.
3. **Hand-roll a scale-on-press `ButtonStyle`.** Rejected: a bespoke imitation of system
   behaviour, which is exactly what this project avoids, and it would not fix the
   hit-testing half of the symptom.

Recorded as parked on option 1 unless the operator decides the press response is worth
option 2.

*Four wrong hypotheses before the right question got asked.* The one that finally split the
problem open was not about Cuety at all — "does any **SwiftUI** toolbar do this correctly?"
Checking the counter-example's source rather than trusting its reputation is what settled
it.

**Done when:** every exposed setting produces a visible, predictable result, and no layout
truncates or overflows at the window sizes in `V10`/`V11`.

---

### Release readiness

| ID | Work | Done when | Done |
|---|---|---|---|
| R1 | App icon asset | A real icon ships in `Assets.xcassets`; no placeholder | [ ] |
| R2 | Formatter configuration, four-space indentation retained | Config committed **before** any mechanical reformatting; lint output reflects it | [ ] |
| R3 | Address the 279 remaining lint diagnostics (mostly wrapping and indentation) after `R2` | Clean lint run, or a documented allowlist | [ ] |
| R4 | Project metadata still says `MyApp/Info.plist` and `productName = MyApp` | All references say Cuety; build settings verified via `GetTargetBuildSettings` | [ ] |
| R5 | User-specific Xcode scheme metadata is tracked in git | Untracked and git-ignored | [ ] |
| R6 | No shared scheme | A shared scheme is checked in and builds from a clean clone | [ ] |
| R7 | No README | README covers what Cuety is, requirements, and how to build | [ ] |
| R8 | Deployment target — audit macOS 27-only API usage | Inventory of every API forcing macOS 27 (Liquid Glass / current SwiftUI APIs), with the back-deployment cost per item; then the target decision is recorded in the decisions log | [ ] |
| R9 | No CI workflow | CI builds and runs tests on push | [ ] |

> `R8` is an inventory task first. Do not lower the target until the inventory exists —
> the answer changes `F14`'s available layout APIs.

---

## Verification

Run against **populated shows**, not empty workspaces. The current tests cover protocol and
authorization behaviour well but leave product behaviour largely untested.

**`V-gap`** — ~~The disconnect test asserts that cue lists are cleared, but its peer starts
with *no cue lists*, so the assertion holds vacuously and cannot expose `F1`.~~ **Closed
with `F1`.** `AuthorizationPeer` now serves cues and answers `playbackPositionID`, and
`QLabDisconnectTests.populatedShow` gives every disconnect test a show with cues in it and
a playhead parked on one. Disconnect coverage can be trusted from here.

| ID | Scenario | Covers | Done |
|---|---|---|---|
| V1 | Connection loss during presentation mode | `F1` | [ ] |
| V2 | Skipped and manual playhead moves with nothing fired | `F3`, `F6` | [ ] |
| V3 | Different group modes, including advancing past a group | `F3`, `F4` | [ ] |
| V4 | Cue edits while detail pills are visible | `F5` | [ ] |
| V5 | Deleting the watched cue list | `F6` | [ ] |
| V6 | Delayed replies arriving after a timeout | `F8` | [ ] |
| V7 | Burst traffic overflowing the event buffer | `F9` | [ ] |
| V8 | Multiple windows — confirm they can no longer be opened | `F7` | [ ] |
| V9 | Keychain failures on save and delete | `F11` | [ ] |
| V10 | Narrow window | `F14` | [ ] |
| V11 | Long cue names and long/unusual cue numbers | `F14` | [ ] |
| V12 | Accessibility settings — Reduce Motion, VoiceOver, contrast | `F14` | [ ] |
| V13 | Passcode connection, then inspect and copy from the Activity Log | `F2` | [ ] |

All thirteen precede the final visual-polish sign-off.

`V1`, `V2` and `V13` now have automated coverage of the parts a test can reach — cue-data
invalidation on a drop, the corrected drawer strings and labels, and passcode redaction
across storage and the clipboard. What is left in each is the part that needs a real QLab
and a pair of eyes: the stage-scale loss state actually appearing in presentation mode, a
hand-moved playhead reading correctly, and the Activity Log inspected and copied after a
passcoded connection. They stay open.

---

## Notes on scope

Justified as-is, per the audit — do not "simplify" these:

- The custom OSC codec and SLIP framer are legitimate protocol implementations using
  Network.framework's native extension mechanism.
- SwiftUI glass effects, Keychain, font discovery and display-sleep prevention all use
  platform APIs.
- Framer callbacks required by the framework are not dead code merely because no Swift
  call site invokes them.

The genuinely unnecessary custom mechanisms are exactly three: the error-description
protocol (`F13`), the guessed drawer-column sizing (`F14`), and the scattered
state-binding adapters (`S1`).
