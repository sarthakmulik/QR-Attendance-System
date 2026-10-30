# Attendify — Next-Phase Design (application perfecting + ERP integration)

Status: DESIGN ONLY — no API code yet. This is the build-ready blueprint for (A)
closing every remaining flow gap/race in the app, and (B) the ERP integration
layer. Decisions locked with the owner: **enrollment = move-with-history**,
**geofence = 50m with GPS-accuracy compensation**.

---

## 1. System flow map (as it stands after the bugfix pass)

```
                    ┌─────────────────────────────────────────────────────────┐
                    │ IDENTITY                                                │
   Invite staged    │  invite_or_claim_user (RPC) ──► user_invites (+class/roll)│
   (Users/Students) │        │ claim at signup                                 │
                    └────────┼──────────────────────────────────────┬──────────┘
                             ▼ handle_new_user trigger               ▼ rolePending
                    MFA signup → public.users (role_assigned TRUE/FALSE)
                             │
   ┌─────────────────────────┼───────────────────────────────────────────────┐
   │ LECTURE CYCLE           ▼                                               │
   │ Lectures.tsx ─ create session (client mints session_secret,              │
   │   expires_at, current token) ──► attendance_sessions (RLS: entitlement)  │
   │      │                                                                   │
   │      ├── LiveSession.tsx: TOTP QR every 10s, PUT current_token,          │
   │      │   poll records 5s, End Lecture (is_active=false)                  │
   │      └── Projector (public): display_token → secret → same TOTP          │
   │                                                                         │
   │ SCANNER: {sessionId, token} → mark_attendance RPC:                       │
   │   login→role→cleanup→session active→expiry→TOTP±1→class resolve→        │
   │   DIVISION GATE→DEVICE GATE→GEOFENCE(100m)→ race-safe INSERT             │
   │                                                                         │
   │ REPORTING: dashboards (1/5/60s) + Reports.tsx (live SQL RPCs)            │
   └─────────────────────────────────────────────────────────────────────────┘
```

Everything below (§2–§6) fits into this skeleton without restructuring it.

---

## 2. Locked behavioral decisions

| Topic | Decision | Consequence in design |
|---|---|---|
| Re-assignment | **Move with history** | enrollments get `active` + `ended_at`; "MOVE" = close old row(s) in one transaction with the new upsert |
| Geofence | **50 m with accuracy compensation** | reject only when `distance − gps_accuracy > 50`; client tightens accuracy gate from 200 m → 50 m ... (see §4 rule) |
| Device binding | 1 device = 1 student / session (already shipped) | plus §3.5 device-seam review for localStorage-clear bypass |
| Sessions | one active session per (class, date) slot | unique-partial-index design in §4.1 |
| Absences | materialize absent rows on session close | denominator becomes rows, not derived math (§3.2) |

---

## 3. Missing flows — to add

### 3.1 Enrollment lifecycle (MOVE-with-history)
Today: re-invite/re-import into class B leaves the class-A enrollment active →
student is denominator-member of both classes, and (worse) could scan class-A QRs.
Design:

```
users.sql trigger/invite RPC change (ONE transaction):
  ┌ new enrollment (student, class B) accepted
  ├─► UPDATE enrollments SET active=false, ended_at=NOW()
  │     WHERE student_id=? AND class_id<>B AND active=true   ← close others
  ├─► UPSERT (student, class B) roll_number
  └─► if roll_number unique conflicts (class B, roll taken) → Reject with
      message naming the other student (no silent overwrite)
```
- All *new* filters (`is_student_in_scope`, divider gate, stats RPCs, CSV import)
  add `WHERE e.active` / `e.ended_at IS NULL` (one predicate, everywhere).
- Closed enrollments stay for history/reports (never deleted).
- Migration step: backfill `active=true` for existing rows; detect students
  with >1 active enrollment and report them in a one-time NOTICE for manual
  confirmation (don't auto-close legacy ambiguity silently).

### 3.2 Absence ledger (materialize on close)
Today `absent` exists as an enum but there are no absent rows — everything is
derived. Two problems: denom/numer mismatch, and no decision trail.
Design:
- New hook point: **when a session closes** (faculty End Lecture button or
  expiry auto-close) → one RPC `close_session(session_id)` which:
  1. `UPDATE sessions SET is_active=false WHERE id=? AND is_active` (returns
     whether this call actually closed it → prevents double-close side effects),
  2. `INSERT attendance_records (session_id, student_id, status='absent',
     device_info=NULL)` for every active-enrolled student without a present row,
     `ON CONFLICT DO NOTHING`.
- `mark_attendance` already inserts `present`; `late` becomes available when a
  session sets `late_cutoff_at` (optional; default none → everything is present).
- Downsides handled: dashboards/CSV keep shape; `get_recent_scans` excludes
  `absent` from the live feed (nobody "scan-arrived" as absent) with WHERE status
  <> 'absent'.

### 3.3 Cancelled-day as denominator hygiene
- Timetable is "expected lecture". If faculty never starts a session that day,
  students of that class are not automatically penalized because total comes
  from *sessions*, not timetable rows. **Keep that rule**, but document it:
  absent rows exist only per *held* sessions. (Optional P2: "no-lecture"
  announcements so students see "holiday" instead of silent miss.)

### 3.4 Onboarding wizard (first 10 minutes for a new college)
Today a super_admin must hop 5 pages in the right order. Design a one-page
wizard typed by role `super_admin` at `/onboarding`:
1. College profile → calls existing `create_college_with_admin` (stages principal).
2. Departments N → direct insert (existing permission).
3. Classes per dept (+division, class_teacher email → invite RPC).
4. Subjects Csv paste (existing CSV modal pattern reused).
5. Students bulk CSV (existing RPC path; MOVE semantics).
6. Projector URLs copied per class + device install checklist.
Skippable steps + progress persisted in `onboarding_state` (localStorage is
enough for v1). Wizard only lists steps; no new DB work besides §3.1 rules.

### 3.5 Device-seam review (the localStorage bypass)
Attack: student clears localStorage → new attendance session, new device token →
device gate never fires for prior proxy (hardened index is per-session anyway).
Pragmatic design (no biometrics):
- Add `device_token_changes` audit: on successful scan where
  `split_part(device_info,'|',1)` differs from the last token recorded for this
  (student) in the last 24h → log row into `device_events` (student, session,
  old/new token hash, UA, lat/lng, timestamp).
- Management dashboard chip: "N suspicious device changes (7 days)" → Review
  list → actions: dismiss / mark attendance invalid (admin override RPC).
- Hardening knob (per college): optionally REJECT a scan if the same student
  produced >3 device tokens within one active session window. Default OFF.

### 3.6 Role-pending service surface for admins
`rolePending` users (role_assigned=FALSE) are invisible today. Add to Users.tsx
tree: "Pending approvals" bucket (hero red) listing those rows + one-click
"Assign role" (already exists via edit dialog) — the AuthContext retry already
handles wait; admin just needs visibility.

### 3.7 Password-reset completion UX
Reset email lands on `/login` signed-in. Design: after recovery sign-in
(`onAuthStateChange` detect `USER_RECOVERED`/no-password-confirm) → toast +
navigate to `/settings#security` where the new change-password dialog lives.
(Small router anchor, no new route.)

---

## 4. Race conditions — full ledger with final state

| # | Race / attack | Status now | Final design |
|---|---|---|---|
| 4.1 | Two active sessions per same timetable slot (faculty double-click "Start") | BUG-free-ish: banner shows ghost, but 2 live sessions can exist | `CREATE UNIQUE INDEX uq_one_active_per_slot ON attendance_sessions (timetable_id, date) WHERE is_active AND timetable_id IS NOT NULL` → 2nd Start fails with clear message; ad-hoc sessions excluded (timetable_id NULL) |
| 4.2 | Enrollment removed after divison gate, before INSERT (TOCTOU) | **Open window** (gate check + insert aren't atomic) | Make INSERT atomic: `INSERT … SELECT … WHERE EXISTS(enrollment for (student,class))` so a removed enrollment can't sneak a record in |
| 4.3 | Session closed between gate-check and INSERT | Open window | Same atomic INSERT: `AND s.is_active` in the SELECT joins, so a closed session can't accept a late scan joining path |
| 4.4 | Duplicate scan race (double-submit / two tabs) | FIXED (ON CONFLICT + both indexes) | keep |
| 4.5 | Device proxy across students | FIXED (pre-check + partial unique index) | keep + §3.5 |
| 4.6 | Batch CSV import partial failure, no transaction | Open | §5.3 bulk RPC: single transaction, returns per-row results array |
| 4.7 | Token brute-force | OK (32-bit TOTP + ±1 window + device/geofence) | retire `current_token` client PUSH entirely once migrations land (§6 P0.4); keep fallback only for legacy sessions |
| 4.8 | Fake GPS | Inherent limitation | 50m radius + accuracy + device events reduce; documented trust boundary |
| 4.9 | `can_signup_with_email` enumeration (probe invites) | By design, mild | add rate limit in Edge/Proxy later (P2) |
| 4.10 | RPC re-enrollment while session open changing class | covered by 4.2 atomicity |  |
| 4.11 | matview/triggers removed — stale reads impossible | FIXED | single-source: live SQL only |
| 4.12 | AuthContext retry post-logout overwrite | Known minor | add `cancelled` flag in cleanup of fetch retry (P1) |

The bugfix pass already removed the *deterministic* bugs; §4.2–4.3 are the only
remaining microseconds-to-admin-action windows and both die with one atomic
INSERT rewrite + one new index (next DB patch, re-runnable file
`schema_flow_fixes.sql` per pattern of `schema_bugfix_pass.sql`).

---

## 5. ERP integration architecture (SPEC ONLY — do not build yet)

### 5.0 Principles
1. **Own DB is the source of truth for attendance**; ERPs are mirrors.
2. Two independent channels, can be adopted separately:
   - **Pull API (REST v1)** — ERPs read data whenever they want.
   - **Push webhooks** — ERPs subscribe; we deliver events, at-least-once.
   - **Inbound roster sync** — ERP is source of truth for people/classes; we
     reconcile nightly (or on-demand) with MOVE semantics.
3. Never expose service_role or direct PostgREST to ERPs; everything through
   **Supabase Edge Functions** holding the service key server-side.
4. Per-college credentials, scopes, audit. One bad tenant can't affect others.

### 5.1 Credentials & auth (applies to all three channels)
```
erp_connections            api_keys
─────────────────────      ────────────────────────────────
id                         id
college_id   ──FK──┐       connection_id ──FK──► erp_connections
provider  (text)   │       key_id        (public half, e.g. "ak_live_xxx")
status             │       secret_hash   (SHA-256; raw shown once at creation)
base_url?          │       scopes        (text[]: students:read, attendance:read,
created_at         │                            roster:write, webhooks:manage…)
last_sync_at?      │       rate_limit_ppm (default 120)
                           revoked_at, last_used_at
```
- Auth header: `Authorization: Bearer ak_live_xxx.sk_live_<raw>`; functions hash
  secret, constant-time compare, load connection + scopes → enforce college +
  scope per endpoint.
- Every request logged to `api_audit_log (api_key_id, endpoint, method,
  status, bytes, latency, ip)`; adjudication + revocation live in Settings →
  Integrations (new admin page, role-gated super_admin/principal).

### 5.2 Pull API (REST v1) — endpoint catalog
All requests: JSON, tenant = key's college (never cross-tenant). Versioned path
`/functions/v1/erp/v1/…` (Edge Function router with per-endpoint submodules).

| Endpoint | Scope | Semantics |
|---|---|---|
| GET /v1/students | students:read | paged (`?cursor=`), filter `?class_id&modified_since` |
| GET /v1/classes | classes:read | incl. teacher, division, rollout info |
| GET /v1/enrollments | students:read | `?active=true&class_id` — reflects MOVE state |
| GET /v1/sessions | attendance:read | `?from&to&class_id` |
| GET /v1/attendance | attendance:read | `?session_id` **or** `?class_id&date` — returns per-student present/late/absent (post-§3.2 rows) |
| GET /v1/defaulters | attendance:read | `?threshold=75` |
| GET /v1/summary | attendance:read | dept / subject / monthly shapes (reuse report SQL) |
| GET /v1/health | — | connectivity + college metadata |

Contract: RFC-style error object `{ error: { code, message, details? }, event_id? }`,
HTTP codes real (401 scope / 403 college / 404 / 409 conflict / 429 with
Retry-After). Cursor pagination: opaque base64 `(created_at, id)`; max page 200.
Idempotency: GETs are safe; mutating inbound endpoints require
`Idempotency-Key` header (stored 24h).

### 5.3 Inbound roster sync (ERP → us)
`POST /v1/roster/sync` — scope `roster:write`. Payload is a **whole-college
snapshot** (classes + students + enrollments w/ external IDs), idempotent upsert:

```
for each class (by external_id): upsert → internal class_id (display_token kept)
for each student (external_id): upsert users by external_id_map (keyed
    college_id+provider+external_id); if absent, create staged invite/email
enrollments:  desired = payload set
    close = active − desired            → SET active=false, ended_at=NOW()   (MOVE)
    open  = desired − active            → insert / reactivate (ended_at=NULL)
diff report returned: {created, updated, closed, reactivated, conflicts[]}
```
- Conflicts (roll_number occupied, role mismatch, duplicate email) are
  *reported*, never silently dropped; either the caller fixes and re-syncs, or
  admin resolves with the standard UI.
- Trigger both nightly (pg_cron call into the ERP's API — the pull direction of
  the roster, if provider allows) OR the ERP pushes. Channel choice is per
  provider adapter; the model above is channel-neutral.

### 5.4 Push webhooks (we → ERP)
**Outbox pattern (exactly the reason it survives crashes):**
```
webhook_events
  id uuid, college_id, connection_id, event_type, payload jsonb,
  created_at, status ('pending','delivered','failed','dead'),
  attempts int default 0, next_retry_at, last_status_code, last_error
```
Write path: business RPCs (mark attendance insert, close_session, enrollment
upserts) append rows to `webhook_events` **in the same transaction** as the
state change. Dispatcher:
- pg_cron every minute → `deliver_webhooks()` Edge Function picks pending +
  `next_retry_at <= now()`, ordered by created_at, POSTs with
  `X-Attendify-Signature: t=<unix>.<hex(hmac_sha256(secret, t + '.' + body))>`
  (timestamped HMAC, mirrors how Stripe does it — ERP side verifies and
  rejects >5-minute-old timestamps), `X-Attendify-Event-Id` for idempotent
  receivers.
- Retry backoff 1m → 5m → 30m → 2h → 6h (5 tries) → `dead` + surfaced in the
  Integrations page with a redeliver button.
- Event catalog v1 (keep minimal): `attendance.marked`,
  `session.closed` (with the full absent/present manifest — most ERPs only
  need this one), `student.enrolled`, `student.reassigned` (MOVE), 
  `defaulter.crossed` (computed on close_session when % crosses below
  threshold). Payloads carry `event_id`, `occurred_at`, college scoping — the
  ERP dedups on `event_id`.

### 5.5 What we do NOT do (v1)
- No generic adapter marketplace; per-provider adapter effort (ERPNext/Fedena/etc.)
  maps their field → our sync schema. First target = whichever ERP the
  partner college runs (ask for a sample roster export; adapters are thin).
- No direct DB replication, no OTA file drops, no manual imports beyond the
  standardized inputs already existing in the UI (CSV).
- No mobile SDK yet; ERP teams get REST + webhooks, that's v1 scope.

---

## 6. Application work queue (build order)

**P0 — DB integrity (one re-runnable `schema_flow_fixes.sql`)**
1. §3.1 enrollments MOVE + `active`/`ended_at` migration + predicate updates.
2. §4.2–4.3 atomic `mark_attendance` INSERT rewrite (enrollment + is_active checks in the INSERT).
3. §4.1 one-active-session-per-slot index (with clear duplicate error).
4. §3.2 `close_session(session_id)` RPC: idempotent close + absent rows + hook point for §5.4 outbox (table can exist now, dispatcher later).

**P0 — Frontend**
5. Close via `close_session` in LiveSession button + auto-expiry path (Scanner's cleanup stays as safety net).
6. MOVE-aware enrollment UI (no more "duplicated student" rows after re-add).
7. Pending-approvals bucket (§3.6).
8. 50m + accuracy compensation in mark_attendance + Scanner client gate tuned (`accuracy > 50 → "Step closer / improve GPS"`; reject server-side only by compensated rule).

**P1**
9. Bulk-rollRPC CSV import (replaces N sequential calls; queues P0.4 pattern).
10. Device-events review list (§3.5) + Integrations landing page skeleton (empty state explains the planned flow, links endpoints doc).
11. AuthContext retry cancellation.
12. `supabase gen types` step in CI (stop untyped `any` creep).

**P2**
13. Onboarding wizard (§3.4).
14. Late-status cutoff UI (`late_cutoff_at` on session form).
15. Rate limiting + API keys UI + first real provider adapter.

---

*Corrections to watch while building: keep every new SQL re-runnable (drop-first
loops + guarded DDL), keep all report-output column names stable (CSV contracts),
and treat `attendance_records` shape (columns + statuses) as a public contract
the ERP layer will consume — changes there now ripple into v1 API.*
