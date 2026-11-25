# Authentication and Session Architecture

**Labels:** `wayfinder:grilling`, `resolved`

## Question

How should staff authentication, role verification, and session persistence work between the HTML frontend and Supabase?

## Resolution

Use **Supabase Auth (`signInWithPassword`)** paired with **`public.staff_profiles`** (keyed to `auth.users.id`) rather than a custom Express/users-table auth server. Role authorization reads strictly from `staff_profiles.role` (never `user_metadata`), `handleStaffLogin` verifies the selected UI role matches the database role, and RLS protects every public table and `security_invoker = true` view.
