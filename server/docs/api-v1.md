<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 Steven Fitzpatrick -->

# Moment Tally API v1

The Moment Tally server speaks GraphQL on `POST /graphql`. This document
describes the v1 contract — the first Moment Tally-owned schema, no longer
traggo-compatible. The full schema is [`../schema.graphql`](../schema.graphql);
this page covers the concepts and the operations a client needs.

## Vocabulary

- **Label** — a `key: value` dimension attached to a timespan
  (e.g. `repo: moment-tally`, `type: review`). The Prometheus mental model:
  time series with dimensions.
- **Label definition** — registers a key for a user: the key plus its
  display color and any per-value color overrides. A key must be defined
  before it can appear on a timespan.
- **Label set** — a named, ordered, launchable combination of labels with an
  SF Symbol icon (the launcher cards in the mac app).

Label keys are lower-case and contain no spaces; the server rejects
anything else at definition time.

## Authentication

Unchanged in shape from the traggo lineage: `login(username, pass,
deviceName, type, cookie)` returns a device token, sent on subsequent
requests as `Authorization: traggo <token>`. Device management
(`devices`, `createDevice`, `updateDevice`, `removeDevice`,
`removeCurrentDevice`) and user administration (`users`, `createUser`,
`updateUser`, `removeUser` — admin only) are unchanged. A GraphQL
playground is served on `GET /graphql` for browsers.

## Label definitions and colors

```graphql
type LabelDefinition {
    key: String!
    color: String!                     # the key color (hex, e.g. "#2196f3")
    valueColors: [LabelValueColor!]!   # per-value overrides, sorted by value
    usages: Int!                       # how many of the user's timespans use the key
}
type LabelValueColor { value: String!, color: String! }
```

Queries:

- `labelDefinitions: [LabelDefinition!]` — all of the current user's
  definitions, most-used first.
- `suggestLabelKey(query): [LabelDefinition!]` — prefix search on keys.
- `suggestLabelValue(key, query): [String!]` — values previously used with
  the key (substring match, max 10).

Mutations:

- `createLabelDefinition(key, color)` / `updateLabelDefinition(key, newKey,
  color)` / `removeLabelDefinition(key)` — key CRUD. Renaming a key
  rewrites it on the user's timespans, dashboard entries, and value-color
  rows; removing deletes its timespan labels and value colors.
- `setLabelValueColor(key, value, color)` — set or replace the color
  override for one value of a key. Returns the updated definition.
- `clearLabelValueColor(key, value)` — remove the override; the value falls
  back to the key color.

Value colors are per user, per key, per value — the server-side
replacement for the mac app's local `valueColors` overlay.

## Label sets

```graphql
type LabelSet {
    id: Int!
    name: String!
    symbolName: String!    # SF Symbol for the launcher card
    labels: [Label!]!      # ordered members
    quickLabels: [Label!]! # ordered quick labels (one-click refinements)
}
```

- `labelSets: [LabelSet!]` — the current user's sets in launcher order.
- `createLabelSet(name, symbolName, labels, quickLabels, position)` —
  appends to the launcher order, or inserts at the optional 0-based
  `position` (clamped). Member order is the input order.
- `updateLabelSet(id, name, symbolName, labels, quickLabels, position)` —
  replaces name, symbol, and members wholesale; the optional `position`
  also moves the set (omitted = stays put).
- `moveLabelSet(id, position)` — move a set to a 0-based position
  (clamped); returns all sets in their new order.
- `removeLabelSet(id)` — deletes the set and its members (quick ones
  included).

**Quick labels** are a set's one-click refinements — the chips the mac app
offers when hovering the set. They belong to the set and sync with it, but
they are a separate ordered list from `labels`. On `createLabelSet` /
`updateLabelSet` the `quickLabels` argument is *optional*, and that is the
whole backward-compatibility story (there is no runtime API version
negotiation): a client that omits it — any client predating quick labels —
leaves the set's existing quick labels untouched (`createLabelSet`: the set
starts with none), while an explicit empty list clears them. Old clients
are also unaffected on the read side: GraphQL only returns the fields a
query requests.

Set members (quick ones included) are *not* required to reference existing
label definitions — sets are launcher conveniences; definitions are
enforced where labels attach to timespans.

### The default collection

The server keeps a collection of template label sets (no owner, flagged
`default_collection`). When a user is created — via the `createUser`
mutation, the admin CLI, or the fresh-database default admin — the
collection is copied to them, and a label definition (color
`#2196f3`) is created for every referenced key they don't already have.
The collection is managed with the admin CLI:

```sh
admin add-default-set -name "Deep Work" -symbol brain.head.profile -labels "type=programming"
admin list-default-sets
admin remove-default-set -id 3
admin seed-user -name someone     # apply the collection to an existing (unseeded) user
```

## Timespans

Timespan shapes and paging are structurally unchanged from the traggo
lineage; the wire now says `labels`:

- `timeSpans(fromInclusive, toInclusive, cursor): PagedTimeSpans!` —
  finished timespans, newest first, stable-cursor paging.
- `timers: [TimeSpan!]` — running timespans (`end == null`).
- `createTimeSpan(start, end, labels, note)`, `updateTimeSpan(id, start,
  end, labels, oldStart, note)`, `stopTimeSpan(id, end)`,
  `copyTimeSpan(id, start, end)`, `removeTimeSpan(id)`.
- `replaceTimeSpanLabels(from, to, opt)` — bulk-rewrite one label
  (key *and* value) across the user's history.

Every label on a timespan must have a defined key (`createLabelDefinition`
first). `Time` values are RFC3339.

## Statistics

`stats(ranges, keys, excludeLabels, requireLabels)` and `stats2(now,
stats)` aggregate time per `key: value` over ranges — the core
aggregations, and the natural backbone of any future web UI.
`InputStatsSelection` uses `keys` / `excludeLabels` / `includeLabels` and a
required `range` (static timestamps or relative expressions like
`now-1d/d`); weeks run Monday through Sunday.

Traggo's dashboards (dashboard/entry/range CRUD and their types) and
`userSettings` (theme, date locale, week start, input style) are **not**
part of v1: Moment Tally is opinionated — stats views belong to the client,
and those settings were web-UI-shaped with no Moment Tally consumer.

## User preferences

The minimal per-user client state a second device should inherit.
Coloring *data* (key and value colors) already syncs via
`LabelDefinition`; these two preferences are what remains:

```graphql
type UserPreferences {
    colorByValue: Boolean!      # color timespans by label value
    menuLabelSetLimit: Int!     # how many label sets the menu shows (0 = all)
}
```

- `userPreferences: UserPreferences!` — the current user's preferences;
  fresh-user defaults are `colorByValue = true` (value-based coloring is
  Moment Tally's default behaviour — key colors remain for navigating Label
  Review) and `menuLabelSetLimit = 5`.
- `setUserPreferences(preferences: InputUserPreferences!)` — replaces both
  values.

## Sync

v1 is sync-capable: a local-first client keeps its own store and
reconciles with the server in the background, last-writer-wins per record.
Two mechanisms support that:

**`updatedAt` timestamps.** Every syncable record — `TimeSpan`,
`LabelDefinition`, `LabelValueColor`, `LabelSet`, `UserPreferences` —
carries `updatedAt: Time!`: the server time of its last write, truncated
to whole seconds so a value that round-trips through RFC3339 still
compares exactly. Clients resolve conflicts by comparing a record's
server `updatedAt` against the wall-clock time of their own unpushed
edit; the newer write wins. `UserPreferences.updatedAt` is the zero time
(`0001-01-01T00:00:00Z`) until the user first writes preferences, so any
device's real edit wins over never-set defaults. Rows that predate the
timestamps report the unix epoch — ancient, so they lose to any real
edit. Bulk operations that rewrite labels on timespans
(`updateLabelDefinition` with `newKey`, `replaceTimeSpanLabels`) bump the
affected timespans' `updatedAt` so the rewrites reach syncing devices.

**The timespan delta feed.** Timespans are the one high-cardinality
entity, so instead of snapshot pulls they get a changes-since query:

```graphql
timeSpanChanges(since: Time!, afterId: Int!, limit: Int): TimeSpanChanges!

type TimeSpanChanges {
    timeSpans: [TimeSpan!]!      # written after (since, afterId), ordered by (updatedAt, id)
    deleted: [DeletedTimeSpan!]! # tombstones with deletedAt >= since
    hasMore: Boolean!
    now: Time!                   # server time, for "last synced" display
}
type DeletedTimeSpan { id: Int!, deletedAt: Time! }
```

The checkpoint is a `(since, afterId)` pair. First sync: the zero time
and `0`. While `hasMore` is true, continue with the last returned span's
`(updatedAt, id)` — the id tie-break is what lets a page full of
same-second writes advance. `limit` defaults to (and is capped at) 200.
Running spans travel through the feed like any other change.

`removeTimeSpan` writes a tombstone; `deleted` returns them with
`deletedAt >= since`, so a deletion is re-delivered rather than ever
missed (dropping an already-absent span is a no-op). Tombstones whose id
is a live timespan again are suppressed. Deletions of snapshot-pulled
entities (label sets, definitions, value colors) need no tombstones: a
record the client knew as synced that is absent from the next snapshot
was deleted on the server.

Low-cardinality entities — `labelDefinitions` (key and value colors ride
along), `labelSets` (quick labels ride along), `userPreferences` — sync
by whole snapshot each pass; their `updatedAt` values drive the same
last-writer-wins rule. The optional `position` argument on
`createLabelSet` / `updateLabelSet` exists so a sync client can push a
set's launcher slot in the same call. A launcher reorder bumps
`updatedAt` only on sets whose position actually changed. A set's quick
labels have no timestamps of their own: writing them (when the
`quickLabels` argument is present — see "Label sets") bumps the set's
`updatedAt` like any other set edit, so the set snapshot wins or loses as
one record, both lists included.

## Renames from the traggo wire (for importers)

| traggo (pre-v1)             | Moment Tally v1                          |
|-----------------------------|---------------------------------------|
| `tags` query                | `labelDefinitions`                    |
| `TagDefinition`             | `LabelDefinition` (+ `valueColors`, − `user`) |
| `createTag` / `updateTag` / `removeTag` | `createLabelDefinition` / `updateLabelDefinition` / `removeLabelDefinition` |
| `suggestTag` / `suggestTagValue` | `suggestLabelKey` / `suggestLabelValue` |
| `TimeSpanTag` / `InputTimeSpanTag` | `Label` / `InputLabel`          |
| `TimeSpan.tags`, `tags:` args | `TimeSpan.labels`, `labels:` args   |
| `replaceTimeSpanTags`       | `replaceTimeSpanLabels`               |
| `stats(…, tags, excludeTags, requireTags)` | `stats(…, keys, excludeLabels, requireLabels)` |
| `StatsSelection.tags/excludeTags/includeTags` | `InputStatsSelection.keys/excludeLabels/includeLabels` (`rangeId` dropped, `range` now required) |
| `dashboards` + dashboard/entry/range CRUD and types | *dropped*       |
| `userSettings` / `setUserSettings` + `Theme`/`DateLocale`/`WeekDay`/`DateTimeInputStyle` | *dropped* |
| —                           | `userPreferences` / `setUserPreferences` |
| —                           | `labelSets` + label-set mutations     |
| —                           | `setLabelValueColor` / `clearLabelValueColor` |

`StatInput`, `DashboardSize` (unused upstream), and the output-side
`StatsSelection` / `RelativeOrStaticRange` types were dropped as well.
