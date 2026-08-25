# Moment Tally server

The Moment Tally sync server: a headless, label-based time-tracking backend
speaking GraphQL. The [Moment Tally mac app](../) is the client — there is no
web UI in this tree.

The API is **Moment Tally v1** — see [docs/api-v1.md](docs/api-v1.md). It
speaks the label vocabulary (labels, label definitions with key *and*
per-value colors, per-user label sets with a seeded default collection)
and is not traggo-compatible.

## Provenance

This tree is a derivative of [traggo/server](https://github.com/traggo/server)
(GPL-3.0), vendored via `git subtree` at commit
`6321119c3c2d55f04e2e4967f6492aabd6067b76` and modified:

- the embedded web UI and its build/release machinery are removed — the
  GraphQL API (timespans, tags, users/auth/devices) is the product here;
- the Go module is renamed to `momenttally.com/server`;
- an admin CLI is added under `cmd/admin` for the user administration the
  web UI used to provide;
- the GraphQL contract is evolved into Moment Tally v1: label vocabulary on
  the wire, per-value label colors, and server-side label sets. Derived Go
  internals deliberately keep traggo's naming (`model.TagDefinition`, the
  `tag`/`timespan` packages, table names) to keep upstream fixes
  cherry-pickable; the schema and all new code say *label*.

See the repository history for the full record of modifications.

Licensing: traggo-derived code (every file without an SPDX header) is
GPL-3.0 ([LICENSE](LICENSE)); Moment Tally-authored additions carry
`SPDX-License-Identifier: AGPL-3.0-or-later` headers
([LICENSE.AGPL-3.0](LICENSE.AGPL-3.0)) — a combination GPLv3 §13
permits. See [NOTICE](NOTICE) for the full statement.

## Running

```sh
make download-tools   # installs gqlgen + goimports
make generate         # gqlgen: regenerates generated/ (gitignored)
go build -o build/moment-tally-server .
./build/moment-tally-server
```

Configuration is via `MOMENTTALLY_*` environment variables or `.env` — see
[.env.sample](.env.sample). Defaults: port 3030, sqlite3 database, and a
default `admin`/`admin` user created when the database is empty.

A GraphQL playground is served on the `/graphql` endpoint for browser
requests; the API is `POST /graphql` with
`Authorization: traggo <device token>`.

For container deployment see [../infra/](../infra/).

## Admin CLI

```sh
go run ./cmd/admin -h
```

Subcommands: `create-user`, `reset-password`, `list-users`, `list-devices`,
plus management of the default label-set collection new users are seeded
with: `list-default-sets`, `add-default-set`, `remove-default-set`, and
`seed-user` (apply the collection to an existing user).
The CLI operates directly on the database; point it at the same
`MOMENTTALLY_DATABASE_*` configuration as the server.
