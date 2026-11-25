# Wayfinder Map — UNICARE Backend & DBA Architecture

## Destination

Deliver a verified, 3NF-normalized Supabase PostgreSQL backend (`supabase/migrations/*`, `supabase/full_setup.sql`, `supabase/verify_dba.sql`), auth provisioning script, DBA design documentation, and zero-theme-regression frontend wiring for UNICARE (Recto Medical).

## Notes

- Domain terms: [GLOSSARY.md](../../GLOSSARY.md)
- Architectural decision: [0001-supabase-postgres-3nf-and-rls.md](../adr/0001-supabase-postgres-3nf-and-rls.md)
- Skills consulted: `wayfinder`, `grill-me`, `domain-modeling`, `supabase`, `supabase-postgres-best-practices`, `modern-web-guidance`
- Constraint: Preserve 100% of CSS/theme bytes in `unicare-v2-complete-updated-v14.html`.

## Decisions so far

- [Database Platform Selection](./tickets/01-database-platform.md): Selected Supabase (PostgreSQL) over local MySQL 8.0 and PHP/MySQL for native RLS, partial unique indexes, PL/pgSQL RPCs, and Supabase Studio ERD visibility.
- [Authentication and Session Architecture](./tickets/02-auth-and-security.md): Selected Supabase Auth (`signInWithPassword`) paired with `public.staff_profiles` and strict PostgreSQL RLS (`TO authenticated`, `security_invoker = true` views).
- [Patients, Encounters, and Billing Normalization](./tickets/03-core-domain-model.md): Selected full 3NF separation across `patients`, `admissions`, `appointments`, `billing_ledgers`, `prescription_items`, and `payment_events`.
- [Pharmacy Catalog, Batches, and Stock Traceability](./tickets/04-pharmacy-inventory-model.md): Selected `medications` catalog + `medication_batches` (partial unique active batch) + immutable `stock_movements`.
- [Role Enforcement and Admin History Override](./tickets/05-rbac-and-admin-override.md): Selected strict 4-role RLS with non-persisting supervisor auth and 30-minute `history_access_overrides` + `audit_logs`.
- [Project Delivery Layout and Local Setup](./tickets/06-delivery-and-connection.md): Selected zero-build modular `supabase/` SQL + `full_setup.sql` + `supabase-config.js`/`supabase-api.js` + `serve.mjs` with local preview fallback when keys are blank.

## Not yet specified

_None — all architectural decisions resolved and ready for implementation._

## Out of scope

- Replacing the single-page HTML layout with a React/Next.js or Vite build pipeline.
- Deploying to production hosting or configuring external third-party payment gateways.
