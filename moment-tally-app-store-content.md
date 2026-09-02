# Moment Tally v1.2.0 App Store Listing Content

Initial Mac App Store submission. Vocabulary per the branding doc
(gitea #27): **Mark** (key: value dimension), **Moment** (span of time),
**Tally** (reusable one-click timer). "Label", "tag", and the Prometheus
framing stay out of front-of-house copy. Style note: `key: value` with a
space, matching the in-app copy.

## Name

Moment Tally — Time Tracker

*(27/30 chars. Plain "Moment Tally" is on-brand too, but nothing else in
name or subtitle would say "time tracker", and the name field is the
heaviest search signal.)*

## Subtitle

Mark the moments of your day

*(28/30 chars — the front half of the masthead line; the back half opens
the promotional text and description.)*

## Categories

Productivity, Utilities

*(Was Productivity + Developer Tools. Issue #27 widens the audience —
only two of the fourteen personas are programming-adjacent — so the
developer positioning moves out of the categories too.)*

## Promotional Text

Mark the moments of your day and see where the effort goes. New in 1.2:
iCloud sync — your moments, marks, and tallies on every Mac, end-to-end
encrypted.

*(155/170 chars. Updatable without review — rotate freely.)*

## Description

Moment Tally is a menu-bar time tracker for the moments that make up
your life. Mark any span of time — any color, any symbol, any scheme —
then look back with calendars, charts, and stats that answer how the
days actually went.

No account. No subscription. Everything lives on your Mac, and iCloud
sync is built in for when you want your history everywhere.

Mark Time Exactly How You Want:
• Marks are simple key: value pairs — client: acme, recipe: sourdough,
course: linear-algebra, instrument: piano. Your time becomes queryable
across any axis you invent, not filed into one rigid hierarchy of
categories.
• Save the schemes you use every day as Tallies — one-click timers with
their own colors and quick marks.

Real Days Overlap:
• Run several timers at once, edit freely after the fact, and attach
notes — because moments interrupt each other and need correcting.
• The Log keeps an honest, editable record: days, entries, notes, and
running totals. Adjust start and end times, marks, and notes whenever
you like.

See Where the Effort Goes:
• Calendars, charts, and stats built from your own marks answer how the
days actually went.
• Group History by any mark you invent — then add a second grouping to
compare, so time by client and time by project sit side by side.

Keep Your Scheme Honest:
• Vocabulary drifts — one week says project:, a stray day says proj:.
Mark Review shows every key and value with usage counts and cleans up
drift with a drag or a rename, before it muddies your charts.

Quiet in the Menu Bar:
• Moment Tally lives entirely in your menu bar — no Dock icon, no window
clutter. Click the timer icon to start, stop, and switch; open the full
window when you want to explore. An interactive Tour teaches the mark
model with realistic sample data.

Your Data Is Yours:
• Local first: a database on your Mac, fully functional offline.
• iCloud sync keeps your moments, mark colors, tallies, and settings the
same on every Mac — end-to-end encrypted, so neither Apple nor Street
Fortress can read your data. Prefer your own hardware? A self-hosted
Moment Tally Server works too.
• When it's time for the books, export your complete, schema-versioned
history to JSON whenever you want it. Coming from Traggo? A built-in
importer copies your full history, keys, and colors.

## Keywords

time tracker,timer,timesheet,productivity,habit,journal,billable,freelance,hours,offline,private

*(97/100 chars. Dropped from the old set: tags/labels (retired
vocabulary), programming (audience widening); "moment", "tally", and
"mark" are already covered by name/subtitle. Added habit, journal,
hours for the general-audience personas. Deliberately no "icloud" —
Apple trademarks in keywords risk rejection.)*

## What's New in This Version (1.2.0)

iCloud sync is here. Turn it on in Settings → Sync and your moments,
mark colors, tallies, and settings stay the same on every Mac —
end-to-end encrypted, offline edits catch up on the next sync.

## Screenshot copy (5)

As provided, with vocabulary fixes where the sub still said
"labels"/"label sets" (retired by gitea #27; the shipped UI already says
marks/tallies — App Store copy shouldn't use words the app no longer
does).

### 01 Hero — unchanged
- **Headline:** Welcome to Moment Tally.
- **Sub:** Mark the moments of your day and see where the effort goes.

### 02 Log — sub reworded
- **Headline:** Your time is data.
- **Sub:** Every moment carries key: value marks — queryable, editable,
  yours.
- *(Was "Mark any moment with key:value labels…" — "labels" is retired,
  and "mark … with marks" reads redundant; this keeps the noun form.)*

### 03 Calendar — unchanged
- **Headline:** Meet the Anti-Schedule.
- **Sub:** No blocking time in advance — your calendar builds itself
  from the moments you actually worked.
- *(Optional widening: "…the moments you actually recorded" — "worked"
  is the one word here that narrows back to the work audience.)*

### 04 History — sub reworded
- **Headline:** See where the effort goes.
- **Sub:** Group by any mark you invent — clients, projects, recipes,
  habits.
- *(Was "any label you invent".)*

### 05 Tallies (was "Label Sets") — retitled and reworded
- **Headline:** Your marks, your rules.
- **Sub:** Save your schemes as Tallies — one-click timers where every
  key: value mark gets its own color.
- *(Was "Your labels, your rules." / "Name the sets behind one-click
  timers…" — the screen itself is now the Tally launcher.)*

Note: none of the five screenshots shows the headline v1.2.0 feature
(iCloud sync / Settings → Sync). Consider a sixth shot, or let the
promotional text and What's New carry it.

## App Review Notes

> Goes in App Store Connect → App Review Information → Notes. Leave the
> demo-account fields blank and "Sign-in required" unchecked — there is no
> account. Practical orientation first (menu-bar-only apps are a known
> "app doesn't launch" rejection pattern), optional features explained so
> they aren't flagged as untestable, motivation last.

Thanks for reviewing Moment Tally — this is our first App Store
submission.

Where the app lives: Moment Tally is a menu-bar-only app. After
launch there is no Dock icon or window — look for the timer icon on
the right side of the macOS menu bar. Click it to start and stop
timers; choose "Open Moment Tally" in that menu to open the full
window (Log, Calendar, History, and the Tally launcher).

No account or sign-in is required, and every feature works offline
with local data. On first launch the app offers an interactive Tour
that walks through the whole app with realistic sample data — the
fastest way to see each feature in action.

iCloud sync (new in this version) is optional and off by default:
Settings → Sync → "Use iCloud". It uses the Mac's signed-in iCloud
account (CloudKit private database, end-to-end encrypted); the app is
fully functional without it.

Two other optional features require infrastructure a reviewer won't
have, and nothing else depends on them: Settings → Sync can instead
connect to a self-hosted Moment Tally Server (for users who prefer
syncing through their own hardware), and Settings → Import can copy
history from a self-hosted Traggo server (a migration path for users
of that open-source tracker).

About the app: Moment Tally exists because most time trackers force
your time into one fixed hierarchy of projects and categories. Here
every span of time carries simple key: value marks — client: acme,
recipe: sourdough — so people can slice their days along any axis
they invent, and the calendar and charts are built from what actually
happened rather than what was scheduled.
