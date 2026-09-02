# Moment Tally v1.2.0 — App Review Response #1

Response to the Guideline 2.1 "Information Needed — New App Submission"
message (2026-09-01). This is Apple's standard template for developer
accounts with limited review history — it cites no concrete defect, so
the job is a complete, verifiable reply, not a bug hunt.

Per their instructions the reply text below goes in **two places**:

1. App Store Connect → the reply thread on the rejection message
   (attach the screen recording there, or host it and link).
2. App Store Connect → App Review Information → **Notes** — appended
   after the existing notes from `moment-tally-app-store-content.md`,
   for reference on future submissions.

Vocabulary per gitea #27: Marks / Moments / Tallies, `key: value` with
a space. No Prometheus framing front-of-house.

---

## Reply text

Thank you for the review. Answers to each item below; the screen
recording is attached.

Some background, since this account is new to App Review: Moment
Tally is an evolving project making its first App Store submission.
It has been publicly distributed for macOS as open source (AGPL-3.0) via
Homebrew and notarized GitHub releases (https://github.com/sf1tzp/moment-tally),
with a product site at https://moment-tally.com. This submission brings
the same app to the Mac App Store.

**1. Screen recording**

The attached recording was captured on a physical Mac running the
latest macOS. It begins with launching the submitted build from
Applications and shows the typical user flow: the app appears as a
menu-bar icon (it is a menu-bar-only app — no Dock icon), the
first-launch interactive Tour, creating a Tally, running and
stopping timers, editing an entry, and the Log, Calendar, History,
and Mark Review views, ending with the optional iCloud sync toggle
in Settings.

The app has no account system — no registration, login, or account
deletion flows exist. It has no user-generated content that is
shared with or visible to other users; all data is private time
entries stored on the user's own device (and optionally in their
own iCloud private database), so content reporting and blocking
mechanisms do not apply.

**2. Purpose and target audience**

Moment Tally is a menu-bar time tracker for individuals —
freelancers tracking billable hours, and anyone who wants an honest
record of where their time goes (studying, practice, hobbies,
habits). The problem it solves: most time trackers force time into
one rigid hierarchy of projects and categories. In Moment Tally,
every span of time carries simple key: value marks (client: acme,
recipe: sourdough), so users can slice their history along any axis
they invent, run overlapping timers the way real days actually
overlap, and review their days with calendars, charts, and stats
built from what actually happened.

**3. Setup and access instructions**

No login credentials or sample files are required — every feature
works immediately, offline, with local data. After launch, look for
the timer icon on the right side of the macOS menu bar (there is no
Dock icon or window at first). Click it to start and stop timers;
choose "Open Moment Tally" in that menu for the full window (Log,
Calendar, History, Tally launcher). On first launch the app offers
an interactive Tour that walks through every feature with realistic
sample data — the fastest way to exercise the app. iCloud sync is
optional and off by default (Settings → Sync → "Use iCloud").

**4. External services, tools, and platforms**

None, beyond Apple's own CloudKit: the optional iCloud sync uses
the user's private CloudKit database, end-to-end encrypted. There
are no third-party data providers, authentication services, payment
processors, analytics, or AI services, and the app never connects
to any server we operate — we run no backend at all.

For completeness, two screens in Settings accept a user-supplied
address: Settings → Sync can point at a sync server the user hosts
on their own hardware instead of iCloud, and Settings → Import can
copy history one time from a self-hosted instance of the
open-source Traggo tracker. These are advanced options for
self-hosting enthusiasts, not services the app depends on — there
is no hosted instance of either, they need no credentials from us,
and everything shown in the recording works with both left
unconfigured.

**5. Regional differences**

None — the app functions identically in all regions. There is no
regional content, no region-gated features, and no server-side
variation; the only per-region difference is App Store pricing
tiers.

**6. Regulated industries / protected third-party material**

Not applicable. The app operates in no regulated industry and
contains no protected third-party material; all code and assets are
our own or properly licensed.

---

## Screen recording — plan

**Setup**

- Physical Mac on the latest macOS (macmini or macbook-air —
  whichever is current), screen recorded with QuickTime /
  Shift-Cmd-5. Silent; no narration needed. Target 2–4 minutes.
- Build: the submitted 1.2.0 MAS build. Cleanest is TestFlight for
  Mac; a dev-signed build of the same commit from `dist/` is an
  acceptable substitute. **Not** the Homebrew instance — different
  signing, Sparkle updater, and a personal dataset.
- Fresh data container so first-launch onboarding actually appears.

**Shot list**

1. Finder → Applications → double-click Moment Tally.
2. Point at the menu-bar timer icon appearing (linger a beat — this
   preempts the "app doesn't launch" pattern for menu-bar-only apps).
3. First-launch Tour: click through it fully; its realistic sample
   data doubles as the populated-app demo.
4. Create a Tally (a couple of key: value marks, pick colors); start
   it from the menu bar.
5. Start a second overlapping timer; stop both.
6. Open the full window: Log — edit an entry's times, add a note.
7. Calendar view (overlapping spans sharing columns).
8. History — group by a mark key, add a second grouping.
9. Mark Review — show keys/values with usage counts, rename one.
10. Settings → Sync → toggle "Use iCloud" on.
11. *(Optional, if low-effort)* a Screen Sharing window to a second
    Mac visible while an entry syncs across. Nice-to-have only.
12. *(Optional)* Settings → Export JSON, to close on the
    data-is-yours point.

If Calendar/History look sparse from live-recorded data, use Demo
Mode for shots 7–9 — same data the store screenshots use, and the
interactions are real.

**Hosting/attachment**: ASC reply threads accept attachments up to a
size limit; if the recording is too large, host an unlisted link and
paste the URL in the reply and Notes.

---

## Checklist

- [ ] Record and trim the video (shot list above)
- [ ] Post reply text + attachment in the ASC reply thread
- [ ] Append reply text to App Review Information → Notes
- [ ] Resubmit the same build (no binary change needed — this is an
      information request, not a defect report)
