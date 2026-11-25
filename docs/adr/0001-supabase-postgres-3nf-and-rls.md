# Supabase PostgreSQL 3NF Schema, Batch Traceability, and Audited RLS

---
status: accepted
---

We are replacing the in-memory JavaScript arrays of UNICARE (Recto Medical) with a persistent relational backend for a combined Web Development and Database Administration final project. Rather than running a local-only MySQL 8.0 Express server or a flat `encounters` table, we chose **Supabase (PostgreSQL 15+)** with full 3NF separation (`patients`, `admissions`, `appointments`, `billing_ledgers`, `prescription_items`, `payment_events`), lot-level `medication_batches` + immutable `stock_movements`, and strict Row-Level Security across the four staff roles including time-bound `history_access_overrides`.

## Considered Options

- **Local MySQL 8.0 + Node/Express REST API**: Strong offline ACID/ERD story, rejected due to higher auth/RBAC boilerplate and lack of native partial unique indexes and database-level RLS.
- **Flat `encounters` + single-table `medications`**: Closer to the original prototype arrays, rejected because overloading patient, admission, and invoice columns into nullable fields creates update anomalies and overwrites batch/promissory audit trails.

## Consequences

- **Database-enforced invariants**: Active bed locks (`UNIQUE (bed_id) WHERE discharged_at IS NULL`), one-active-batch-per-drug (`UNIQUE (medication_id) WHERE status = 'Active'`), OPD 3/3 slot limits, isolation hard-blocks, and exact invoice arithmetic (`CHECK` constraints) live inside PostgreSQL instead of only client JS.
- **Immutable auditability**: `stock_movements`, `payment_events`, and `audit_logs` are append-only, preserving both Promissory Note issuance and subsequent payment alongside expired-batch disposals.
- **Security boundaries**: All tables enforce RLS `TO authenticated` via `private` `SECURITY DEFINER` helpers reading `staff_profiles` (never `user_metadata`), all reporting views use `security_invoker = true`, and frontend configuration uses only the public Supabase URL and publishable key.
