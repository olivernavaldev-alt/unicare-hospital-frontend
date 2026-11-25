# Database Platform Selection

**Labels:** `wayfinder:grilling`, `resolved`

## Question

Which database and backend stack best satisfies both the Web Development and Database Management Administration final project requirements for UNICARE?

## Resolution

**Supabase (PostgreSQL)** is locked in. PostgreSQL provides native 3NF constraints, partial unique indexes (for active bed locks and active pharmacy batches), `CHECK` constraints, PL/pgSQL transactional RPCs, triggers, `security_invoker = true` analytical views, Row-Level Security (RLS) across all four staff roles, and Supabase Studio's live ERD visualizer for defense review.
