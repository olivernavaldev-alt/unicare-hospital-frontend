-- ============================================================================
-- UNICARE (Recto Medical) — 002_rls_and_security.sql
-- Private SECURITY DEFINER helpers, explicit grants, and 4-role RLS policies
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Non-exposed private schema for SECURITY DEFINER authorization helpers
-- ----------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.current_staff_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
    select sp.role
    from public.staff_profiles sp
    where sp.id = (select auth.uid())
      and sp.is_active = true
    limit 1;
$$;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(private.current_staff_role() = 'Hospital Administrator', false);
$$;

create or replace function private.has_active_history_override()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.history_access_overrides hao
        where hao.target_staff_id = (select auth.uid())
          and hao.revoked_at is null
          and hao.expires_at > now()
    );
$$;

revoke all on function private.current_staff_role() from public, anon;
revoke all on function private.is_admin() from public, anon;
revoke all on function private.has_active_history_override() from public, anon;
grant execute on function private.current_staff_role() to authenticated;
grant execute on function private.is_admin() to authenticated;
grant execute on function private.has_active_history_override() to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Explicit Schema, Table, Sequence & View Grants (Least Privilege)
-- ----------------------------------------------------------------------------
grant usage on schema public to authenticated;
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

grant select on all tables in schema public to authenticated;
grant insert, update on
    public.patients,
    public.admissions,
    public.appointments,
    public.medications,
    public.medication_batches,
    public.billing_ledgers,
    public.history_access_overrides,
    public.daily_receipt_counters
    to authenticated;
grant insert on
    public.prescription_items,
    public.stock_movements,
    public.payment_events,
    public.audit_logs
    to authenticated;
grant insert, update, delete on
    public.staff_profiles,
    public.doctors,
    public.illness_categories,
    public.rooms,
    public.room_allowed_illnesses,
    public.beds
    to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Enable Row-Level Security on ALL 18 public tables
-- ----------------------------------------------------------------------------
alter table public.staff_profiles enable row level security;
alter table public.doctors enable row level security;
alter table public.illness_categories enable row level security;
alter table public.rooms enable row level security;
alter table public.room_allowed_illnesses enable row level security;
alter table public.beds enable row level security;
alter table public.patients enable row level security;
alter table public.admissions enable row level security;
alter table public.appointments enable row level security;
alter table public.medications enable row level security;
alter table public.medication_batches enable row level security;
alter table public.billing_ledgers enable row level security;
alter table public.prescription_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.payment_events enable row level security;
alter table public.history_access_overrides enable row level security;
alter table public.audit_logs enable row level security;
alter table public.daily_receipt_counters enable row level security;

-- ----------------------------------------------------------------------------
-- 4. Reference Tables (Read: authenticated staff; Write: Administrator)
-- ----------------------------------------------------------------------------
create policy doctors_select_staff on public.doctors
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy doctors_admin_insert on public.doctors
    for insert to authenticated
    with check ((select private.is_admin()));
create policy doctors_admin_update on public.doctors
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

create policy illness_categories_select_staff on public.illness_categories
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy illness_categories_admin_insert on public.illness_categories
    for insert to authenticated
    with check ((select private.is_admin()));
create policy illness_categories_admin_update on public.illness_categories
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

create policy rooms_select_staff on public.rooms
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy rooms_admin_insert on public.rooms
    for insert to authenticated
    with check ((select private.is_admin()));
create policy rooms_admin_update on public.rooms
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

create policy room_allowed_illnesses_select_staff on public.room_allowed_illnesses
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy room_allowed_illnesses_admin_insert on public.room_allowed_illnesses
    for insert to authenticated
    with check ((select private.is_admin()));
create policy room_allowed_illnesses_admin_update on public.room_allowed_illnesses
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

create policy beds_select_staff on public.beds
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy beds_admin_insert on public.beds
    for insert to authenticated
    with check ((select private.is_admin()));
create policy beds_admin_update on public.beds
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

-- ----------------------------------------------------------------------------
-- 5. Staff Profiles
-- ----------------------------------------------------------------------------
create policy staff_profiles_select_self_or_admin on public.staff_profiles
    for select to authenticated
    using (id = (select auth.uid()) or (select private.is_admin()));
create policy staff_profiles_admin_insert on public.staff_profiles
    for insert to authenticated
    with check ((select private.is_admin()));
create policy staff_profiles_admin_update on public.staff_profiles
    for update to authenticated
    using ((select private.is_admin()))
    with check ((select private.is_admin()));

-- ----------------------------------------------------------------------------
-- 6. Patients, Admissions (IPD), Appointments (OPD)
-- ----------------------------------------------------------------------------
create policy patients_select_staff on public.patients
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy patients_insert_frontdesk_admin on public.patients
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff'));
create policy patients_update_frontdesk_admin on public.patients
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff'));

create policy admissions_select_staff on public.admissions
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy admissions_insert_frontdesk_admin on public.admissions
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff'));
create policy admissions_update_clinical_billing on public.admissions
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff', 'Billing & Discharge Officer'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff', 'Billing & Discharge Officer'));

create policy appointments_select_staff on public.appointments
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy appointments_insert_frontdesk_admin on public.appointments
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff'));
create policy appointments_update_clinical_billing on public.appointments
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff', 'Billing & Discharge Officer'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Front Desk & Admissions Staff', 'Billing & Discharge Officer'));

-- ----------------------------------------------------------------------------
-- 7. Pharmacy Catalog, Batches & Append-Only Stock Movements
-- ----------------------------------------------------------------------------
create policy medications_select_staff on public.medications
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy medications_insert_pharma_admin on public.medications
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'));
create policy medications_update_pharma_admin on public.medications
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'));

create policy medication_batches_select_staff on public.medication_batches
    for select to authenticated
    using ((select private.current_staff_role()) is not null);
create policy medication_batches_insert_pharma_admin on public.medication_batches
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'));
create policy medication_batches_update_pharma_admin on public.medication_batches
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'));

create policy stock_movements_select_pharma_admin on public.stock_movements
    for select to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist'));
create policy stock_movements_insert_pharma_admin on public.stock_movements
    for insert to authenticated
    with check (
        (select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist')
        and performed_by = (select auth.uid())
    );

-- ----------------------------------------------------------------------------
-- 8. Unified Billing Ledgers, Prescription Items & Payment Events
-- ----------------------------------------------------------------------------
create policy billing_ledgers_select_rbac on public.billing_ledgers
    for select to authenticated
    using (
        (select private.is_admin())
        or (
            (select private.current_staff_role()) = 'Billing & Discharge Officer'
            and (
                status in ('Active', 'Promissory Note')
                or (status = 'Paid' and (select private.has_active_history_override()))
            )
        )
        or (
            (select private.current_staff_role()) = 'Front Desk & Admissions Staff'
            and status = 'Active'
            and visit_type in ('Inpatient', 'Outpatient')
        )
        or (
            (select private.current_staff_role()) = 'Hospital Pharmacist'
            and status = 'Active'
        )
    );

create policy billing_ledgers_insert_rbac on public.billing_ledgers
    for insert to authenticated
    with check (
        (select private.is_admin())
        or (
            (select private.current_staff_role()) = 'Front Desk & Admissions Staff'
            and status = 'Active'
            and visit_type in ('Inpatient', 'Outpatient')
        )
        or (
            (select private.current_staff_role()) = 'Hospital Pharmacist'
            and status = 'Active'
            and visit_type = 'Walk-In OTC'
        )
    );

create policy billing_ledgers_update_billing_admin on public.billing_ledgers
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'));

create policy prescription_items_select_visible_ledger on public.prescription_items
    for select to authenticated
    using (
        exists (
            select 1
            from public.billing_ledgers bl
            where bl.id = billing_ledger_id
        )
    );

create policy prescription_items_insert_pharma_admin on public.prescription_items
    for insert to authenticated
    with check (
        (select private.current_staff_role()) in ('Hospital Administrator', 'Hospital Pharmacist')
        and dispensed_by = (select auth.uid())
    );

create policy payment_events_select_visible_ledger on public.payment_events
    for select to authenticated
    using (
        exists (
            select 1
            from public.billing_ledgers bl
            where bl.id = billing_ledger_id
        )
    );

create policy payment_events_insert_billing_admin on public.payment_events
    for insert to authenticated
    with check (
        (select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer')
        and performed_by = (select auth.uid())
    );

-- ----------------------------------------------------------------------------
-- 9. Settlement History Overrides, Audit Logs & Receipt Counters
-- ----------------------------------------------------------------------------
create policy history_overrides_select_own_or_admin on public.history_access_overrides
    for select to authenticated
    using (target_staff_id = (select auth.uid()) or (select private.is_admin()));

create policy history_overrides_insert_admin_only on public.history_access_overrides
    for insert to authenticated
    with check (
        (select private.is_admin())
        and granted_by_admin_id = (select auth.uid())
    );

create policy history_overrides_update_own_or_admin on public.history_access_overrides
    for update to authenticated
    using (target_staff_id = (select auth.uid()) or (select private.is_admin()))
    with check (target_staff_id = (select auth.uid()) or (select private.is_admin()));

create policy audit_logs_select_admin_only on public.audit_logs
    for select to authenticated
    using ((select private.is_admin()));

create policy audit_logs_insert_authenticated on public.audit_logs
    for insert to authenticated
    with check (
        (select private.current_staff_role()) is not null
        and actor_staff_id = (select auth.uid())
    );

create policy daily_receipt_counters_select_billing_admin on public.daily_receipt_counters
    for select to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'));
create policy daily_receipt_counters_insert_billing_admin on public.daily_receipt_counters
    for insert to authenticated
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'));
create policy daily_receipt_counters_update_billing_admin on public.daily_receipt_counters
    for update to authenticated
    using ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'))
    with check ((select private.current_staff_role()) in ('Hospital Administrator', 'Billing & Discharge Officer'));

commit;
