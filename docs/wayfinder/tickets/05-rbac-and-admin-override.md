# Role Enforcement and Admin History Override

**Labels:** `wayfinder:grilling`, `resolved`

## Question

How should PostgreSQL enforce permissions for the four hospital staff roles while still supporting the Billing Officer's temporary Settlement History unlock modal?

## Resolution

Enforce strict per-role RLS policies via `private` schema `SECURITY DEFINER` helpers (`private.current_staff_role()`, `private.is_admin()`, `private.has_active_history_override()`). To unlock Settlement History without switching the active session away from the Billing Officer, `#admin-unlock-modal` authenticates the supervisor on a non-persisting secondary Supabase client, calls `grant_history_override()` (inserting a 30-minute row in `history_access_overrides` + `audit_logs`), and discards the supervisor token. **Lock Session** immediately calls `revoke_history_override()`.
