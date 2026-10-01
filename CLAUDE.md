# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Jigoleberks Tournament PWA — a self-hosted Progressive Web App for club-scale catch-photo-release fishing tournaments. Members log catches from their phone (in-app camera, offline-capable), and a live leaderboard re-renders via Turbo Streams over Action Cable.

Ruby 3.3.6, Rails 8.0, PostgreSQL 16, Hotwire (Turbo + Stimulus), Solid Queue/Cache/Cable, Tailwind CSS v4, Importmap for JS.

## Commands

All development commands run through Docker Compose:

```bash
# Start the app
docker compose up

# Run a one-off Rails command
docker compose run --rm web bin/rails <command>

# Database setup
docker compose run --rm web bin/rails db:create db:migrate db:seed

# Run the full test suite
docker compose run --rm web bin/rails test
docker compose run --rm web bin/rails test:system

# Run a single test
docker compose run --rm web bin/rails test test/models/user_test.rb
docker compose run --rm web bin/rails test test/models/user_test.rb:42

# Rails console
docker compose exec web bin/rails console
```

## Authentication

Custom-built (no Devise). Magic-link sign-in via `SignInToken` (email-delivered or console-fetched). Also supports 8-digit codes with attempt tracking. Session stores `user_id`.

Two distinct authorization concepts on `User`:
- **Per-club role** — lives on `ClubMembership`, enum `member` (0) or `organizer` (1). A user can be a member in one club and an organizer in another.
- **Site admin** — boolean `admin:` flag on `User` directly, scope-free. Site admins can create/manage clubs and edit/invite members across clubs ("approved to use this server's hardware", not a per-club role). Bootstrap the first admin with `User.find_by(email: …).update!(admin: true)`.

`Authentication` concern (`app/controllers/concerns/authentication.rb`) provides `current_user`, `signed_in?`, `require_sign_in!`, `sign_in!`, `sign_out!`.

Base controller patterns enforce access:
- `Organizers::BaseController` — requires organizer role in the current club
- `Judges::BaseController` — requires judge assignment for a specific tournament
- `Api::BaseController` — requires sign-in, returns 401 (not redirect)
- `Admin::BaseController` — requires organizer in the current club (laptop admin UI)
- `Admin::Clubs::BaseController` — requires `admin: true` on `User` (cross-club operations)

### Temporary deputy organizers (accepted-risk widening of the organizer gate)

A `TournamentDeputy` grant gives a member full organizer access until the target tournament's `starts_at`, at which point it lapses lazily (evaluated on read via `User#active_deputy_in?` — no expiry job). This is intentional: a deputy helps build the field for a league night, then becomes a competitor again at kickoff.

`User#organizer_in?` — the gate checked by `Organizers::BaseController`, `Admin::BaseController`, `Judges::BaseController`, the home-page nav, `CatchesHelper`, and `Leaderboards::ViewerScope` — deliberately admits deputies. `User#permanent_organizer_in?` is the narrower gate: it excludes deputies and is what `require_permanent_organizer!` enforces.

**Only privilege-*granting* actions are hardened with `require_permanent_organizer!`** (role changes at `PATCH /admin/members/:id/role`, and deputy grants themselves) — this stops a deputy from making their own badge permanent. **Every other organizer action is reachable by a deputy during their pre-`starts_at` window**, including `Admin::MembersController#issue_code` (mint a sign-in code for any member → impersonation), self-assigning as a judge, and adding members.

This is an **accepted risk** — the model assumes small, trusted clubs and a soft anti-cheat posture. Do NOT tighten these gates (e.g. move `#issue_code` behind `require_permanent_organizer!`) without asking first. Conversely, when adding a new privilege-granting action, gate it with `require_permanent_organizer!`, not the widened `organizer_in?`.

## Routing

Namespaced areas plus public routes:
- `/organizers/*` — tournament CRUD, member management, judge assignment, catch history, templates (mobile-friendly)
- `/judges/tournaments/:tournament_id/*` — catch review (approve/flag/DQ/manual override)
- `/admin/*` — laptop admin UI; organizer-only; same data as `/organizers/*` with a wider layout
- `/admin/clubs/*` — site-admin only; create clubs, invite/manage members across clubs, and manage each club's banner, acknowledgment notices, questionnaire questions and heat map
- `/api/*` — offline catch submission, push subscription management
- Public: catches logging, tournament leaderboards, sign-in flow

## Domain Models

Multi-club: a single deployment can host multiple `Club`s. Tournaments, templates, and per-club roles are club-scoped; `User`s and `Species` are global. Users join clubs via `ClubMembership` (which carries the per-club role); a single user can belong to multiple clubs with different roles.

Core models: `User`, `Club`, `ClubMembership`, `Catch`, `Tournament`, `ScoringSlot`, `TournamentEntry`, `CatchPlacement`, `JudgeAction`, `Species`, `PushSubscription`, `SignInToken`, `TournamentTemplate`, `ClubNotice`, `ClubNoticeRecipient`, `ClubNoticeAcknowledgment`, `ClubQuestion`, `EntryQuestionnaire`, `EntryQuestionnaireAnswer`, `EntryQuestionnaireDismissal`.

Key patterns:
- Soft deletes via `deactivated_at` on User, `active: false` on CatchPlacement
- Append-only audit log for judge actions (`JudgeAction` with `before_state`/`after_state` JSONB)
- Catches have `client_uuid` for offline deduplication

## Services

Business logic lives in `app/services/` using the `Module::Class` pattern with a `self.call` class method interface:

- `Catches::PlaceInSlots` — Core scoring: places a catch into tournament scoring slots, broadcasts leaderboard, triggers push notifications
- `Catches::ApplyFilters` — Applies the catch history / map filters (species, lake, length, time-of-day, month, wind, pressure, moon); shared by `CatchesController#index` and `#map`
- `Catches::FilterBands` — Single source of truth for filter cut points (pressure bands, wind speed bins, moon-phase bins); used by both server-side filtering and the filter-bar UI
- `Catches::HeatMapFilters` — Turns the club heat map's query params into safe, defaulted filter values (species, length, date range); invalid input falls back to a default, never raises
- `Catches::HeatMapPoints` — The club heat map's points: `[lat, lng]` pairs for the club's catches, coordinates only, in shuffled order, from one `pluck`
- `Leaderboards::Build` — Builds ranked leaderboard by summing active placement lengths per entry
- `Placements::BroadcastLeaderboard` — Turbo Stream replace to the tournament channel
- `Placements::DetectNotifications` — Detects bumped-from-slot and took-the-lead events
- `Tournaments::ActiveForUser` — Finds active tournaments a user is entered in
- `Tournaments::WinnersFor` — Batched per-tournament winner lookup for the archived-tournaments index (avoids N+1 across many tournaments)
- `Catches::ApplyJudgeAction` — Applies judge actions (approve/flag/DQ) to catches
- `TournamentTemplates::Clone` — Clones a template into a new tournament
- `Notices::DueFor` — The notices a member must still acknowledge today (active on the day, sent to them, not yet acknowledged for that day); drives the blocking daily popup rendered by both layouts
- `Questionnaires::EligibleEntries` — The boats a finished season-points tournament asks "what worked": its current top three, computed from the standings on every read (never stored), so a post-end disqualification changes who is asked
- `Questionnaires::PendingFor` — A member's home-page questionnaire cards; one query narrows to candidate entries before any leaderboard is built
- `Questionnaires::SaveAnswers` — Write rules for a boat's answers (active questions only, blank clears, at least one answer)
- `Questionnaires::WhatWorked` — Rows for the "What worked" section on a finished tournament's page

## JavaScript / PWA

Stimulus controllers in `app/javascript/controllers/`. Offline support via IndexedDB (`offline/db.js`) and Background Sync (`offline/sync.js`). Service worker registration in `sw_register.js`.

## Tests

Minitest with parallel execution, FactoryBot for factories, and `fixtures :all`. System tests use Cuprite + Chromium (with `--use-fake-device-for-media-stream` for camera tests).

Test directories: `test/models/`, `test/controllers/` (including api/judges/organizers namespaces), `test/services/`, `test/jobs/`, `test/mailers/`, `test/system/`.

## Workflow

- **Re-run the full test suite before any `git push`.** A green run from earlier in the session doesn't cover the most recent edit — run `docker compose exec web bin/rails test` again after the *last* code change, even if it's a one-line redirect or a renamed variable. Don't push and rely on CI to catch regressions; fix them locally first. When changing controller behavior, also scan the matching test file for assertions that depend on the old behavior.
- **Anti-cheat posture is intentionally soft.** Catches carry flags (missing GPS, clock skew) for judge review, but the project has explicitly chosen *not* to add hard enforcement (EXIF validation, perceptual hashing, capture tokens) yet. Don't add those without asking first.
- **After editing `.env`, run `docker compose up -d`, not `docker compose restart`.** `restart` reuses the existing container's environment and won't pick up new values. If `web` fails to boot afterwards, remove a stale `tmp/pids/server.pid` and try again.

## Conventions

- Service objects for non-trivial business logic (`Module::Class` with `self.call`)
- Tailwind utility classes inline in ERB views — no separate CSS files
- Enums stored as integers
- No member self-signup; organizers add members
- Catch photo detail pages gated to organizers/judges only
- Other members' catch coordinates are shown rounded to 2 decimals (about 1 km). The club heat map (`/catches/heat_map`) is the one deliberate exception: it uses exact coordinates, is off per club until a site admin turns it on (`clubs.heat_map_enabled`), and sends the browser coordinates only. Only a site admin can choose its species; members and organizers see Walleye only (not Tagged Walleye), enforced in `CatchesController#heat_map`. Do not add rounding, jitter or a minimum-angler rule to it, and do not add any other catch detail to its pages, without asking first.

## Branching workflow

Day-to-day development happens on the shared `jig_dev` branch — both maintainers push directly to it. Test VMs deploy from `jig_dev`; the prod VM tracks `main`.

- **Pull before you push.** `git pull --rebase origin jig_dev` before starting work and before pushing. Small frequent conflicts are easier to resolve than one big one at PR-merge time.
- **One PR per release cut**, not per commit. When `jig_dev` is in a shippable state, open a PR `jig_dev → main`. Squash-merge to `main` is fine — jig_dev's commit history doesn't need to survive.
- **Dependabot still targets `main`.** After each bump merges to main, resync jig_dev right away — don't let several stack up: `git checkout jig_dev && git merge main && git push` (use a real merge, not `--ff-only`, since jig_dev usually has commits ahead). If a bump touches `Gemfile.lock`, also `docker compose build web` so the running container has the new gems before the next test run. Run the full suite (`bin/rails test` *and* `bin/rails test:system`) before pushing — `test` alone misses system tests, which CI does run.
- **Drain open dependabot PRs before opening a release `jig_dev → main` PR.** Either merge them to main and resync jig_dev first, or roll the bumps into jig_dev as part of the release commits. If they sit open during the release, the squash-merge of the release creates a divergence: main has the dependabot bumps (and the squashed release commit), jig_dev still has its individual release commits, and `jig_dev → main` ends up conflicting on every file both sides touched.
- **Prod hotfixes** branch off `main` directly. After merging to main, merge main into jig_dev.
- The `jig_dev` branch has GitHub branch protection enabled to prevent accidental deletion. Force-push is allowed for history cleanup.
