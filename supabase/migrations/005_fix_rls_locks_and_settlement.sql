-- ============================================================================
-- UNICARE (Recto Medical) — 005_fix_rls_locks_and_settlement.sql
-- Live Patch: Fixes 4 PostgreSQL RLS / Row-Lock Bugs Found During UAT:
--   1. admit_inpatient: advisory bed lock instead of FOR UPDATE OF b (Front Desk RLS)
--   2. dispense_prescription: advisory ledger lock instead of FOR UPDATE OF bl (Pharmacist RLS)
--   3. dispense_prescription: INNER JOIN lock instead of illegal LEFT JOIN ... FOR UPDATE
--   4. settle_billing_ledger & settle_promissory_note: private commit helpers so Billing
--      Officer can transition ledgers to Paid without violating SELECT-on-new-row Paid RLS
-- Safe & idempotent: paste directly into Supabase SQL Editor and click Run.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 3. RPC: Admit Inpatient (IPD) + Auto-Open Active Billing Ledger
-- ----------------------------------------------------------------------------
create or replace function public.admit_inpatient(
    p_patient_name text,
    p_contagious_status text,
    p_illness_category text,
    p_bed_id bigint,
    p_doctor_name text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_clean_name text := trim(coalesce(p_patient_name, ''));
    v_patient_id bigint;
    v_doctor record;
    v_bed record;
    v_admission_id bigint;
    v_ledger_id bigint;
    v_origin text;
begin
    if v_role not in ('Hospital Administrator', 'Front Desk & Admissions Staff') then
        raise exception 'Access denied: % cannot admit inpatients', coalesce(v_role, 'unauthenticated');
    end if;

    if char_length(v_clean_name) < 2 then
        raise exception 'Patient full name must be at least 2 characters';
    end if;

    select d.id, d.full_name, d.consultation_fee
    into v_doctor
    from public.doctors d
    where d.full_name = trim(p_doctor_name) and d.is_active = true;

    if not found then
        raise exception 'Attending specialist (%) not found or inactive', p_doctor_name;
    end if;

    -- Serialize concurrent admissions on the same bed without requiring UPDATE RLS on reference table beds
    perform pg_advisory_xact_lock(hashtext('unicare_bed|' || p_bed_id::text));

    select b.id, b.bed_label, r.room_name
    into v_bed
    from public.beds b
    join public.rooms r on r.id = b.room_id
    where b.id = p_bed_id and b.is_active = true;

    if not found then
        raise exception 'Selected bed (%) does not exist or is inactive', p_bed_id;
    end if;

    select p.id into v_patient_id
    from public.patients p
    where p.normalized_name = lower(v_clean_name)
    order by p.id asc
    limit 1;

    if v_patient_id is null then
        insert into public.patients (full_name)
        values (v_clean_name)
        returning id into v_patient_id;
    end if;

    insert into public.admissions (
        patient_id, bed_id, attending_doctor_id, contagious_status, illness_category, stay_days, admitted_by
    )
    values (
        v_patient_id, p_bed_id, v_doctor.id, p_contagious_status, p_illness_category, 1, (select auth.uid())
    )
    returning id into v_admission_id;

    v_origin := v_bed.room_name || ' • ' || v_bed.bed_label;

    insert into public.billing_ledgers (
        visit_type, patient_id, admission_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status
    )
    values (
        'Inpatient', v_patient_id, v_admission_id, v_clean_name, v_origin, p_illness_category,
        v_doctor.id, v_doctor.consultation_fee, 'Active'
    )
    returning id into v_ledger_id;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'ADMIT_INPATIENT',
        'admission',
        v_admission_id::text,
        jsonb_build_object(
            'patient_id', v_patient_id,
            'patient_name', v_clean_name,
            'bed_id', p_bed_id,
            'origin', v_origin,
            'doctor', v_doctor.full_name,
            'billing_ledger_id', v_ledger_id
        )
    );

    return jsonb_build_object(
        'admission_id', v_admission_id,
        'billing_ledger_id', v_ledger_id,
        'patient_id', v_patient_id,
        'origin_label', v_origin
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. RPC: Atomic Multi-Item Prescription Dispense (Deadlock-Free Batch Locking)
-- ----------------------------------------------------------------------------
create or replace function public.dispense_prescription(
    p_billing_ledger_id bigint,
    p_walkin_name text,
    p_items jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_ledger_id bigint := p_billing_ledger_id;
    v_ledger_status text;
    v_ledger_name text;
    v_ledger_visit_type text;
    v_ticket_code text;
    v_walkin_clean text := trim(coalesce(p_walkin_name, ''));
    v_item record;
    v_med_batch record;
    v_total_cost numeric(12,2) := 0;
    v_days_left integer;
    v_new_balance integer;
    v_expected_lines integer := 0;
    v_locked_lines integer := 0;
begin
    if v_role not in ('Hospital Administrator', 'Hospital Pharmacist') then
        raise exception 'Access denied: % cannot dispense medications', coalesce(v_role, 'unauthenticated');
    end if;

    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Prescription basket is empty';
    end if;

    if v_ledger_id is not null then
        -- Serialize concurrent dispense/settlement on the same ledger without requiring UPDATE RLS on billing_ledgers
        perform pg_advisory_xact_lock(hashtext('unicare_ledger|' || v_ledger_id::text));

        select bl.status, bl.account_label, bl.visit_type
        into v_ledger_status, v_ledger_name, v_ledger_visit_type
        from public.billing_ledgers bl
        where bl.id = v_ledger_id;

        if not found then
            raise exception 'Target billing ledger (%) not found', v_ledger_id;
        end if;
        if v_ledger_status <> 'Active' then
            raise exception 'Cannot dispense to non-active ledger (status: %)', v_ledger_status;
        end if;
    end if;

    -- Stage validated aggregated items in a temp table and lock batches in consistent ID order
    create temporary table if not exists _dispense_lines (
        drug_code text not null,
        qty integer not null
    ) on commit drop;
    truncate table _dispense_lines;

    insert into _dispense_lines (drug_code, qty)
    select upper(trim(elem->>'drug_code')), sum((elem->>'qty')::integer)::integer
    from jsonb_array_elements(p_items) as elem
    group by upper(trim(elem->>'drug_code'));

    if exists (select 1 from _dispense_lines where qty is null or qty <= 0) then
        raise exception 'All dispensed quantities must be positive whole integers';
    end if;

    select count(*)::integer into v_expected_lines from _dispense_lines;

    -- Verify every requested drug_code maps to an Active batch before locking via INNER JOIN
    for v_item in
        select dl.drug_code
        from _dispense_lines dl
        where not exists (
            select 1
            from public.medications m
            join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
            where upper(m.drug_code) = dl.drug_code
        )
    loop
        raise exception 'Medication (%) is unavailable or has no active batch', v_item.drug_code;
    end loop;

    -- Lock active batches ordered by medication_batches.id ASC (INNER JOIN so FOR UPDATE OF mb is valid)
    for v_item in
        select
            dl.drug_code,
            dl.qty,
            m.id as medication_id,
            m.generic_name,
            m.dosage_form,
            m.unit_price,
            mb.id as batch_id,
            mb.stock_qty,
            mb.expiry_date,
            mb.status as batch_status
        from _dispense_lines dl
        join public.medications m on upper(m.drug_code) = dl.drug_code
        join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
        order by mb.id asc
        for update of mb
    loop
        v_locked_lines := v_locked_lines + 1;

        v_days_left := (v_item.expiry_date - current_date)::integer;
        if v_days_left <= 30 then
            raise exception 'Hard Block Error: % (%) is expired or within 30 days of expiry (% days remaining)',
                v_item.generic_name, v_item.drug_code, v_days_left;
        end if;

        if v_item.qty > v_item.stock_qty then
            raise exception 'Stock Error: Requested % units of %, but only % available',
                v_item.qty, v_item.generic_name, v_item.stock_qty;
        end if;
    end loop;

    if v_locked_lines <> v_expected_lines then
        raise exception 'One or more requested medications no longer have an active batch available';
    end if;

    -- Create Walk-In OTC ledger after all inventory checks succeed
    if v_ledger_id is null then
        v_ticket_code := 'OTC-' || nextval('public.otc_ticket_seq')::text;
        v_ledger_name := case
            when v_walkin_clean <> '' then v_walkin_clean || ' (' || v_ticket_code || ')'
            else 'Walk-In Buyer (' || v_ticket_code || ')'
        end;
        v_ledger_visit_type := 'Walk-In OTC';

        insert into public.billing_ledgers (
            visit_type, patient_id, walkin_ticket_code, account_label, origin_label,
            clinical_note, doctor_fee_snapshot, status
        )
        values (
            'Walk-In OTC', null, v_ticket_code, v_ledger_name,
            'Pharmacy Counter • ' || v_ticket_code,
            'Over-the-Counter Pharmacy Purchase', 0, 'Active'
        )
        returning id into v_ledger_id;
    end if;

    -- Apply atomic deductions, prescription line items, and immutable stock movements
    for v_item in
        select
            dl.drug_code,
            dl.qty,
            m.id as medication_id,
            m.generic_name,
            m.dosage_form,
            m.unit_price,
            mb.id as batch_id
        from _dispense_lines dl
        join public.medications m on upper(m.drug_code) = dl.drug_code
        join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
        order by mb.id asc
    loop
        update public.medication_batches
        set stock_qty = stock_qty - v_item.qty
        where id = v_item.batch_id
        returning stock_qty into v_new_balance;

        insert into public.prescription_items (
            billing_ledger_id, medication_id, batch_id,
            drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot, dispensed_by
        )
        values (
            v_ledger_id, v_item.medication_id, v_item.batch_id,
            v_item.generic_name, v_item.dosage_form, v_item.qty, v_item.unit_price, (select auth.uid())
        );

        insert into public.stock_movements (
            batch_id, movement_type, qty_delta, balance_after, billing_ledger_id, note, performed_by
        )
        values (
            v_item.batch_id, 'DISPENSE', -v_item.qty, v_new_balance, v_ledger_id,
            'Dispensed to ' || v_ledger_name, (select auth.uid())
        );

        v_total_cost := v_total_cost + round((v_item.qty * v_item.unit_price)::numeric, 2);
    end loop;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'DISPENSE_PRESCRIPTION',
        'billing_ledger',
        v_ledger_id::text,
        jsonb_build_object(
            'visit_type', v_ledger_visit_type,
            'account_label', v_ledger_name,
            'total_dispensed', v_total_cost,
            'items', p_items
        )
    );

    return jsonb_build_object(
        'billing_ledger_id', v_ledger_id,
        'visit_type', v_ledger_visit_type,
        'account_label', v_ledger_name,
        'walkin_ticket_code', v_ticket_code,
        'total_dispensed', v_total_cost
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. RPCs: Billing Stay Days, Settlement & Promissory Note Payment
-- ----------------------------------------------------------------------------
-- Non-exposed private helpers allow Billing Officers to transition an Active or
-- Promissory ledger to 'Paid' without triggering PostgreSQL's SELECT-on-new-row
-- RLS check (billing.01 remains blocked from SELECTing Paid history without an
-- active 30-minute Administrator override).
create or replace function private.commit_billing_settlement(
    p_ledger_id bigint,
    p_payment_type text,
    p_or_number text,
    p_room_cost numeric,
    p_doctor_cost numeric,
    p_pharmacy_cost numeric,
    p_gross numeric,
    p_discount numeric,
    p_surcharge numeric,
    p_final_total numeric,
    p_ward_released text,
    p_now timestamptz,
    p_actor_id uuid,
    p_actor_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
begin
    if v_role not in ('Hospital Administrator', 'Billing & Discharge Officer') then
        raise exception 'Access denied: % cannot commit billing settlements', coalesce(v_role, 'unauthenticated');
    end if;

    update public.billing_ledgers
    set status = p_payment_type,
        or_number = p_or_number,
        room_cost = p_room_cost,
        doctor_cost = p_doctor_cost,
        pharmacy_cost = p_pharmacy_cost,
        gross_subtotal = p_gross,
        discount_amount = p_discount,
        surcharge_amount = p_surcharge,
        settled_total = p_final_total,
        ward_released = p_ward_released,
        issued_at = p_now,
        issued_by = p_actor_id,
        issued_by_role = p_actor_role,
        paid_at = case when p_payment_type = 'Paid' then p_now else null end,
        paid_by = case when p_payment_type = 'Paid' then p_actor_id else null end,
        paid_by_role = case when p_payment_type = 'Paid' then p_actor_role else null end
    where id = p_ledger_id
      and status = 'Active';

    if not found then
        raise exception 'Billing ledger (%) could not be settled (not Active)', p_ledger_id;
    end if;
end;
$$;

create or replace function private.commit_promissory_payment(
    p_ledger_id bigint,
    p_now timestamptz,
    p_actor_id uuid,
    p_actor_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
begin
    if v_role not in ('Hospital Administrator', 'Billing & Discharge Officer') then
        raise exception 'Access denied: % cannot commit promissory payments', coalesce(v_role, 'unauthenticated');
    end if;

    update public.billing_ledgers
    set status = 'Paid',
        paid_at = p_now,
        paid_by = p_actor_id,
        paid_by_role = p_actor_role
    where id = p_ledger_id
      and status = 'Promissory Note';

    if not found then
        raise exception 'Selected account (%) is not an unpaid Promissory Note', p_ledger_id;
    end if;
end;
$$;

revoke all on function private.commit_billing_settlement(bigint, text, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, timestamptz, uuid, text) from public, anon;
revoke all on function private.commit_promissory_payment(bigint, timestamptz, uuid, text) from public, anon;
grant execute on function private.commit_billing_settlement(bigint, text, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, timestamptz, uuid, text) to authenticated;
grant execute on function private.commit_promissory_payment(bigint, timestamptz, uuid, text) to authenticated;

create or replace function public.update_inpatient_stay_days(
    p_billing_ledger_id bigint,
    p_stay_days integer
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_ledger record;
begin
    if v_role not in ('Hospital Administrator', 'Billing & Discharge Officer') then
        raise exception 'Access denied: % cannot update stay duration', coalesce(v_role, 'unauthenticated');
    end if;

    if p_stay_days is null or p_stay_days < 1 or p_stay_days > 365 then
        raise exception 'Stay duration must be between 1 and 365 days';
    end if;

    select bl.id, bl.visit_type, bl.status, bl.admission_id
    into v_ledger
    from public.billing_ledgers bl
    where bl.id = p_billing_ledger_id
    for update of bl;

    if not found then
        raise exception 'Billing ledger (%) not found', p_billing_ledger_id;
    end if;
    if v_ledger.status <> 'Active' or v_ledger.visit_type <> 'Inpatient' or v_ledger.admission_id is null then
        raise exception 'Stay duration can only be modified on active inpatient ledgers';
    end if;

    update public.admissions
    set stay_days = p_stay_days
    where id = v_ledger.admission_id;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'UPDATE_STAY_DAYS',
        'admission',
        v_ledger.admission_id::text,
        jsonb_build_object('billing_ledger_id', p_billing_ledger_id, 'stay_days', p_stay_days)
    );

    return jsonb_build_object('billing_ledger_id', p_billing_ledger_id, 'stay_days', p_stay_days);
end;
$$;

create or replace function public.settle_billing_ledger(
    p_billing_ledger_id bigint,
    p_payment_type text,
    p_discount numeric default 0,
    p_surcharge numeric default 0
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_ledger record;
    v_adm record;
    v_doc record;
    v_room_cost numeric(12,2) := 0;
    v_doctor_cost numeric(12,2) := 0;
    v_pharmacy_cost numeric(12,2) := 0;
    v_gross numeric(12,2) := 0;
    v_discount numeric(12,2) := round(coalesce(p_discount, 0), 2);
    v_surcharge numeric(12,2) := round(coalesce(p_surcharge, 0), 2);
    v_final_total numeric(12,2) := 0;
    v_seq integer;
    v_or_number text;
    v_now timestamptz := now();
    v_ward_released text;
    v_items jsonb := '[]'::jsonb;
    v_pharm_items jsonb := '[]'::jsonb;
begin
    if v_role not in ('Hospital Administrator', 'Billing & Discharge Officer') then
        raise exception 'Access denied: % cannot settle billing ledgers', coalesce(v_role, 'unauthenticated');
    end if;

    if p_payment_type not in ('Paid', 'Promissory Note') then
        raise exception 'Invalid payment type: %', p_payment_type;
    end if;

    if v_discount < 0 or v_surcharge < 0 then
        raise exception 'Discount and surcharge amounts must be 0 or greater';
    end if;

    perform pg_advisory_xact_lock(hashtext('unicare_ledger|' || p_billing_ledger_id::text));

    select * into v_ledger
    from public.billing_ledgers bl
    where bl.id = p_billing_ledger_id
    for update of bl;

    if not found then
        raise exception 'Billing ledger (%) not found', p_billing_ledger_id;
    end if;

    if v_ledger.status <> 'Active' then
        raise exception 'Billing ledger (%) is already %', p_billing_ledger_id, v_ledger.status;
    end if;

    if v_ledger.visit_type = 'Inpatient' and v_ledger.admission_id is not null then
        select ad.id, ad.stay_days, b.bed_label, r.room_name, r.ward_type, r.daily_rate
        into v_adm
        from public.admissions ad
        join public.beds b on b.id = ad.bed_id
        join public.rooms r on r.id = b.room_id
        where ad.id = v_ledger.admission_id
        for update of ad;

        v_room_cost := round((v_adm.daily_rate * v_adm.stay_days)::numeric, 2);
        v_ward_released := v_adm.room_name || ' • ' || v_adm.bed_label || ' (' || v_adm.ward_type || ' → Available)';
        if v_room_cost > 0 then
            v_items := v_items || jsonb_build_array(
                jsonb_build_object(
                    'title', v_adm.ward_type || ' Room Charges',
                    'subtitle', v_adm.room_name || ' • ' || v_adm.stay_days || ' day' || case when v_adm.stay_days > 1 then 's' else '' end || ' @ ₱' || to_char(v_adm.daily_rate, 'FM999,999,990.00') || '/day',
                    'amount', v_room_cost
                )
            );
        end if;
    else
        v_ward_released := v_ledger.origin_label;
    end if;

    v_doctor_cost := round(coalesce(v_ledger.doctor_fee_snapshot, 0), 2);
    if v_ledger.doctor_id is not null and v_doctor_cost > 0 then
        select d.full_name, d.specialty into v_doc
        from public.doctors d
        where d.id = v_ledger.doctor_id;

        v_items := v_items || jsonb_build_array(
            jsonb_build_object(
                'title', 'Attending Specialist Consultation',
                'subtitle', coalesce(v_doc.full_name || ' (' || v_doc.specialty || ')', 'Attending Physician'),
                'amount', v_doctor_cost
            )
        );
    end if;

    select
        coalesce(sum(pi.subtotal), 0)::numeric(12,2),
        coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'title', 'Central Pharmacy Medications',
                    'subtitle', pi.drug_name_snapshot || ' (' || pi.dosage_form_snapshot || ') • ' || pi.qty || ' unit' || case when pi.qty > 1 then 's' else '' end || ' @ ₱' || to_char(pi.unit_price_snapshot, 'FM999,999,990.00'),
                    'amount', pi.subtotal
                )
                order by pi.id asc
            ),
            '[]'::jsonb
        )
    into v_pharmacy_cost, v_pharm_items
    from public.prescription_items pi
    where pi.billing_ledger_id = v_ledger.id;

    v_items := v_items || v_pharm_items;
    v_gross := round(v_room_cost + v_doctor_cost + v_pharmacy_cost, 2);

    if v_discount > round(v_gross + v_surcharge, 2) then
        raise exception 'Billing Validation Error: Discount (₱%) cannot exceed billable total (₱%)',
            v_discount, round(v_gross + v_surcharge, 2);
    end if;

    v_final_total := round(v_gross - v_discount + v_surcharge, 2);

    insert into public.daily_receipt_counters (receipt_date, last_seq)
    values (current_date, 1)
    on conflict (receipt_date)
    do update set last_seq = public.daily_receipt_counters.last_seq + 1
    returning last_seq into v_seq;

    v_or_number := 'OR-' || to_char(current_date, 'YYYY-MMDD') || '-' || lpad(v_seq::text, 2, '0');

    -- Commit status transition through non-exposed private helper so Billing Officer
    -- SELECT-on-new-row RLS for Paid rows does not block cash settlement
    perform private.commit_billing_settlement(
        v_ledger.id,
        p_payment_type,
        v_or_number,
        v_room_cost,
        v_doctor_cost,
        v_pharmacy_cost,
        v_gross,
        v_discount,
        v_surcharge,
        v_final_total,
        v_ward_released,
        v_now,
        (select auth.uid()),
        v_role
    );

    if v_ledger.visit_type = 'Inpatient' and v_ledger.admission_id is not null then
        update public.admissions
        set discharged_at = v_now
        where id = v_ledger.admission_id and discharged_at is null;
    elsif v_ledger.visit_type = 'Outpatient' and v_ledger.appointment_id is not null then
        update public.appointments
        set status = 'Settled',
            settled_at = v_now
        where id = v_ledger.appointment_id and status = 'Active';
    end if;

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by, performed_by_role, created_at)
    values (
        v_ledger.id,
        case when p_payment_type = 'Paid' then 'SETTLED_PAID' else 'PROMISSORY_ISSUED' end,
        v_final_total,
        (select auth.uid()),
        v_role,
        v_now
    );

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        case when p_payment_type = 'Paid' then 'SETTLE_BILL_PAID' else 'ISSUE_PROMISSORY_NOTE' end,
        'billing_ledger',
        v_ledger.id::text,
        jsonb_build_object('or_number', v_or_number, 'final_total', v_final_total, 'visit_type', v_ledger.visit_type)
    );

    return jsonb_build_object(
        'billing_ledger_id', v_ledger.id,
        'payment_type', p_payment_type,
        'or_number', v_or_number,
        'patient_name', v_ledger.account_label,
        'visit_type', v_ledger.visit_type,
        'ward_released', v_ward_released,
        'issued_at', v_now,
        'issued_by_role', v_role,
        'paid_at', case when p_payment_type = 'Paid' then v_now else null end,
        'paid_by_role', case when p_payment_type = 'Paid' then v_role else null end,
        'settled_at', v_now,
        'settled_by_role', v_role,
        'items', v_items,
        'gross_subtotal', v_gross,
        'discount', v_discount,
        'surcharge', v_surcharge,
        'final_total', v_final_total
    );
end;
$$;

create or replace function public.settle_promissory_note(p_billing_ledger_id bigint)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_ledger record;
    v_adm record;
    v_doc record;
    v_now timestamptz := now();
    v_items jsonb := '[]'::jsonb;
    v_pharm_items jsonb := '[]'::jsonb;
begin
    if v_role not in ('Hospital Administrator', 'Billing & Discharge Officer') then
        raise exception 'Access denied: % cannot settle promissory notes', coalesce(v_role, 'unauthenticated');
    end if;

    perform pg_advisory_xact_lock(hashtext('unicare_ledger|' || p_billing_ledger_id::text));

    select * into v_ledger
    from public.billing_ledgers bl
    where bl.id = p_billing_ledger_id
    for update of bl;

    if not found then
        raise exception 'Billing ledger (%) not found', p_billing_ledger_id;
    end if;

    if v_ledger.status <> 'Promissory Note' then
        raise exception 'Selected account (%) is not an unpaid Promissory Note', p_billing_ledger_id;
    end if;

    if v_ledger.visit_type = 'Inpatient' and v_ledger.admission_id is not null and coalesce(v_ledger.room_cost, 0) > 0 then
        select ad.stay_days, r.room_name, r.ward_type, r.daily_rate
        into v_adm
        from public.admissions ad
        join public.beds b on b.id = ad.bed_id
        join public.rooms r on r.id = b.room_id
        where ad.id = v_ledger.admission_id;

        v_items := v_items || jsonb_build_array(
            jsonb_build_object(
                'title', v_adm.ward_type || ' Room Charges',
                'subtitle', v_adm.room_name || ' • ' || v_adm.stay_days || ' day' || case when v_adm.stay_days > 1 then 's' else '' end || ' @ ₱' || to_char(v_adm.daily_rate, 'FM999,999,990.00') || '/day',
                'amount', v_ledger.room_cost
            )
        );
    end if;

    if v_ledger.doctor_id is not null and coalesce(v_ledger.doctor_cost, 0) > 0 then
        select d.full_name, d.specialty into v_doc
        from public.doctors d
        where d.id = v_ledger.doctor_id;

        v_items := v_items || jsonb_build_array(
            jsonb_build_object(
                'title', 'Attending Specialist Consultation',
                'subtitle', coalesce(v_doc.full_name || ' (' || v_doc.specialty || ')', 'Attending Physician'),
                'amount', v_ledger.doctor_cost
            )
        );
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'title', 'Central Pharmacy Medications',
                'subtitle', pi.drug_name_snapshot || ' (' || pi.dosage_form_snapshot || ') • ' || pi.qty || ' unit' || case when pi.qty > 1 then 's' else '' end || ' @ ₱' || to_char(pi.unit_price_snapshot, 'FM999,999,990.00'),
                'amount', pi.subtotal
            )
            order by pi.id asc
        ),
        '[]'::jsonb
    )
    into v_pharm_items
    from public.prescription_items pi
    where pi.billing_ledger_id = v_ledger.id;

    v_items := v_items || v_pharm_items;

    -- Preserve issued_at / issued_by / issued_by_role untouched; commit via private helper
    -- so Billing Officer SELECT-on-new-row RLS for Paid rows does not block collection
    perform private.commit_promissory_payment(
        v_ledger.id,
        v_now,
        (select auth.uid()),
        v_role
    );

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by, performed_by_role, created_at)
    values (v_ledger.id, 'PROMISSORY_PAID', v_ledger.settled_total, (select auth.uid()), v_role, v_now);

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'SETTLE_PROMISSORY_NOTE',
        'billing_ledger',
        v_ledger.id::text,
        jsonb_build_object('or_number', v_ledger.or_number, 'amount_paid', v_ledger.settled_total)
    );

    return jsonb_build_object(
        'billing_ledger_id', v_ledger.id,
        'payment_type', 'Paid',
        'or_number', v_ledger.or_number,
        'patient_name', v_ledger.account_label,
        'visit_type', v_ledger.visit_type,
        'ward_released', coalesce(v_ledger.ward_released, v_ledger.origin_label),
        'issued_at', v_ledger.issued_at,
        'issued_by_role', v_ledger.issued_by_role,
        'paid_at', v_now,
        'paid_by_role', v_role,
        'settled_at', v_now,
        'settled_by_role', v_role,
        'items', v_items,
        'gross_subtotal', v_ledger.gross_subtotal,
        'discount', v_ledger.discount_amount,
        'surcharge', v_ledger.surcharge_amount,
        'final_total', v_ledger.settled_total
    );
end;
$$;

-- Ensure execute privileges remain scoped to authenticated staff
revoke all on function public.admit_inpatient(text, text, text, bigint, text) from public, anon;
revoke all on function public.dispense_prescription(bigint, text, jsonb) from public, anon;
revoke all on function public.update_inpatient_stay_days(bigint, integer) from public, anon;
revoke all on function public.settle_billing_ledger(bigint, text, numeric, numeric) from public, anon;
revoke all on function public.settle_promissory_note(bigint) from public, anon;
grant execute on function public.admit_inpatient(text, text, text, bigint, text) to authenticated;
grant execute on function public.dispense_prescription(bigint, text, jsonb) to authenticated;
grant execute on function public.update_inpatient_stay_days(bigint, integer) to authenticated;
grant execute on function public.settle_billing_ledger(bigint, text, numeric, numeric) to authenticated;
grant execute on function public.settle_promissory_note(bigint) to authenticated;

commit;
