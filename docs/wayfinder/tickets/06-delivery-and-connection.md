# Project Delivery Layout and Local Setup

**Labels:** `wayfinder:grilling`, `resolved`

## Question

How should the SQL migrations, frontend adapter, local dev server, and setup scripts be structured given the user has not yet created a Supabase project?

## Resolution

Deliver a zero-build modular architecture:
- `supabase/migrations/001_schema.sql` through `004_seed.sql`, plus combined `supabase/full_setup.sql` (one-click SQL Editor paste) and `supabase/verify_dba.sql` (transactional DBA verification test suite).
- `scripts/seed-auth-users.mjs` (creates the 4 Auth users + `staff_profiles` via environment variables).
- `supabase-config.js` + `supabase-api.js` + `serve.mjs` wired into `unicare-v2-complete-updated-v14.html` with automatic local preview fallback when `supabase-config.js` credentials are blank.
- `docs/DATABASE_DESIGN.md` with Mermaid ERD, normalization proof, and a 3-minute setup checklist.
