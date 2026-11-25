-- ============================================================================
-- UNICARE (Recto Medical) — 003_rpcs_and_triggers.sql
-- Domain Integrity Triggers, Atomic SECURITY INVOKER RPCs, and Realtime
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Domain Integrity Triggers
-- ----------------------------------------------------------------------------
create or replace function public.fn_enforce_room_illness_contagious()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_room_status text;
    v_illness_status text;
begin
    select r.contagious_status into v_room_status
    from public.rooms r
    where r.id = new.room_id;

    select ic.contagious_status into v_illness_status
    from public.illness_categories ic
    where ic.category_name = new.illness_category;

    if v_room_status is distinct from v_illness_status then
        raise exception 'Room contagious status (%) does not match illness category (%) status (%)',
            v_room_status, new.illness_category, v_illness_status;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_enforce_room_illness_contagious on public.room_allowed_illnesses;
create trigger trg_enforce_room_illness_contagious
    before insert or update on public.room_allowed_illnesses
    for each row execute function public.fn_enforce_room_illness_contagious();

create or replace function public.fn_enforce_admission_wing_rules()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_room_id bigint;
    v_room_code text;
    v_room_type text;
    v_room_contagious text;
    v_illness_contagious text;
    v_wing_allowed boolean;
begin
    select ic.contagious_status into v_illness_contagious
    from public.illness_categories ic
    where ic.category_name = new.illness_category;

    if v_illness_contagious is null then
        raise exception 'Unknown illness category: %', new.illness_category;
    end if;

    if v_illness_contagious <> new.contagious_status then
        raise exception 'Illness (%) requires contagious status %, got %',
            new.illness_category, v_illness_contagious, new.contagious_status;
    end if;

    select r.id, r.room_code, r.ward_type, r.contagious_status
    into v_room_id, v_room_code, v_room_type, v_room_contagious
    from public.beds b
    join public.rooms r on r.id = b.room_id
    where b.id = new.bed_id and b.is_active = true;

    if v_room_id is null then
        raise exception 'Bed % does not exist or is inactive', new.bed_id;
    end if;

    if v_room_contagious <> new.contagious_status then
        raise exception 'Isolation Hard Block: Cannot place a % patient into Room % (% Wing)',
            new.contagious_status, v_room_code, v_room_contagious;
    end if;

    select exists (
        select 1
        from public.room_allowed_illnesses rai
        where rai.room_id = v_room_id
          and rai.illness_category = new.illness_category
    ) into v_wing_allowed;

    if not v_wing_allowed then
        raise exception 'Disease Wing Hard Block: Room % (%) does not accept % cases',
            v_room_code, v_room_type, new.illness_category;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_enforce_admission_wing_rules on public.admissions;
create trigger trg_enforce_admission_wing_rules
    before insert or update of bed_id, contagious_status, illness_category on public.admissions
    for each row execute function public.fn_enforce_admission_wing_rules();

create or replace function public.fn_enforce_opd_slot_cap()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_active_count integer;
begin
    if new.status <> 'Active' then
        return new;
    end if;

    select count(*)::integer into v_active_count
    from public.appointments ap
    where ap.doctor_id = new.doctor_id
      and ap.appointment_date = new.appointment_date
      and ap.time_slot = new.time_slot
      and ap.status = 'Active'
      and (tg_op = 'INSERT' or ap.id <> new.id);

    if v_active_count >= 3 then
        raise exception 'Scheduling Error: Maximum capacity of 3 active patients reached for this doctor at % on %',
            new.time_slot, new.appointment_date;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_enforce_opd_slot_cap on public.appointments;
create trigger trg_enforce_opd_slot_cap
    before insert or update of doctor_id, appointment_date, time_slot, status on public.appointments
    for each row execute function public.fn_enforce_opd_slot_cap();

create or replace function public.fn_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists trg_medications_updated_at on public.medications;
create trigger trg_medications_updated_at
    before update on public.medications
    for each row execute function public.fn_set_updated_at();

-- ----------------------------------------------------------------------------
-- 2. RPC: Staff Profile & Session Capability Check
-- ----------------------------------------------------------------------------
create or replace function public.get_my_staff_profile()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
    v_profile public.staff_profiles%rowtype;
begin
    select * into v_profile
    from public.staff_profiles sp
    where sp.id = (select auth.uid())
      and sp.is_active = true
    limit 1;

    if not found then
        raise exception 'No active staff profile found for authenticated user';
    end if;

    return jsonb_build_object(
        'id', v_profile.id,
        'username', v_profile.username,
        'email', v_profile.email,
        'full_name', v_profile.full_name,
        'role', v_profile.role,
        'has_history_override', (private.is_admin() or private.has_active_history_override())
    );
end;
$$;

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

    select b.id, b.bed_label, r.room_name
    into v_bed
    from public.beds b
    join public.rooms r on r.id = b.room_id
    where b.id = p_bed_id and b.is_active = true
    for update of b;

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
-- 4. RPC: Book Outpatient Appointment (OPD) + Auto-Open Active Billing Ledger
-- ----------------------------------------------------------------------------
create or replace function public.book_outpatient_appointment(
    p_patient_name text,
    p_doctor_name text,
    p_time_slot text,
    p_appointment_date date default current_date
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_clean_name text := trim(coalesce(p_patient_name, ''));
    v_target_date date := coalesce(p_appointment_date, current_date);
    v_doctor record;
    v_patient_id bigint;
    v_appointment_id bigint;
    v_ledger_id bigint;
    v_queue_pos integer;
    v_origin text;
begin
    if v_role not in ('Hospital Administrator', 'Front Desk & Admissions Staff') then
        raise exception 'Access denied: % cannot book outpatient consultations', coalesce(v_role, 'unauthenticated');
    end if;

    if char_length(v_clean_name) < 2 then
        raise exception 'Outpatient full name must be at least 2 characters';
    end if;

    select d.id, d.full_name, d.specialty, d.consultation_fee
    into v_doctor
    from public.doctors d
    where d.full_name = trim(p_doctor_name) and d.is_active = true;

    if not found then
        raise exception 'Doctor (%) not found or inactive', p_doctor_name;
    end if;

    -- Serialize concurrent bookings for the same doctor + date + time slot
    perform pg_advisory_xact_lock(
        hashtext(v_doctor.id::text || '|' || v_target_date::text || '|' || p_time_slot)
    );

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

    insert into public.appointments (
        patient_id, doctor_id, appointment_date, time_slot, status, booked_by
    )
    values (
        v_patient_id, v_doctor.id, v_target_date, p_time_slot, 'Active', (select auth.uid())
    )
    returning id into v_appointment_id;

    select count(*)::integer into v_queue_pos
    from public.appointments ap
    where ap.doctor_id = v_doctor.id
      and ap.appointment_date = v_target_date
      and ap.time_slot = p_time_slot
      and ap.status = 'Active';

    v_origin := 'Triage • ' || p_time_slot;

    insert into public.billing_ledgers (
        visit_type, patient_id, appointment_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status
    )
    values (
        'Outpatient', v_patient_id, v_appointment_id, v_clean_name, v_origin,
        v_doctor.specialty || ' Consultation', v_doctor.id, v_doctor.consultation_fee, 'Active'
    )
    returning id into v_ledger_id;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'BOOK_OUTPATIENT',
        'appointment',
        v_appointment_id::text,
        jsonb_build_object(
            'patient_id', v_patient_id,
            'patient_name', v_clean_name,
            'doctor', v_doctor.full_name,
            'time_slot', p_time_slot,
            'queue_position', v_queue_pos,
            'billing_ledger_id', v_ledger_id
        )
    );

    return jsonb_build_object(
        'appointment_id', v_appointment_id,
        'billing_ledger_id', v_ledger_id,
        'queue_position', v_queue_pos,
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
begin
    if v_role not in ('Hospital Administrator', 'Hospital Pharmacist') then
        raise exception 'Access denied: % cannot dispense medications', coalesce(v_role, 'unauthenticated');
    end if;

    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Prescription basket is empty';
    end if;

    if v_ledger_id is not null then
        select bl.status, bl.account_label, bl.visit_type
        into v_ledger_status, v_ledger_name, v_ledger_visit_type
        from public.billing_ledgers bl
        where bl.id = v_ledger_id
        for update of bl;

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

    -- Lock active batches ordered by medication_batches.id ASC to prevent deadlocks
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
        left join public.medications m on upper(m.drug_code) = dl.drug_code
        left join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
        order by mb.id asc nulls last
        for update of mb
    loop
        if v_item.medication_id is null or v_item.batch_id is null then
            raise exception 'Medication (%) is unavailable or has no active batch', v_item.drug_code;
        end if;

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
-- 6. RPCs: Upsert Medication Stock, CSV Batch Import & Expired Disposal
-- ----------------------------------------------------------------------------
create or replace function public.upsert_medication_stock(
    p_drug_code text,
    p_batch_no text,
    p_generic_name text,
    p_dosage_form text,
    p_unit_price numeric,
    p_stock_qty integer,
    p_expiry_date date,
    p_low_stock_limit integer default 15,
    p_source text default 'ADD_STOCK'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_code text := upper(trim(coalesce(p_drug_code, '')));
    v_batch text := trim(coalesce(p_batch_no, ''));
    v_name text := trim(coalesce(p_generic_name, ''));
    v_form text := trim(coalesce(p_dosage_form, ''));
    v_movement text := case when p_source = 'CSV_RESTOCK' then 'CSV_RESTOCK' else 'ADD_STOCK' end;
    v_med_id bigint;
    v_active_batch record;
    v_new_batch_id bigint;
    v_delta integer;
    v_action_type text := 'updated';
begin
    if v_role not in ('Hospital Administrator', 'Hospital Pharmacist') then
        raise exception 'Access denied: % cannot modify pharmacy stock', coalesce(v_role, 'unauthenticated');
    end if;

    if char_length(v_code) < 3 or char_length(v_batch) < 2 or char_length(v_name) < 2 or char_length(v_form) < 2 then
        raise exception 'Invalid medication fields provided';
    end if;
    if p_unit_price is null or p_unit_price <= 0 or p_stock_qty is null or p_stock_qty < 0 or p_expiry_date is null then
        raise exception 'Price must be > 0, stock >= 0, and expiry date required';
    end if;

    select m.id into v_med_id
    from public.medications m
    where upper(m.drug_code) = v_code
    for update of m;

    if v_med_id is null then
        insert into public.medications (drug_code, generic_name, dosage_form, unit_price, low_stock_limit)
        values (v_code, v_name, v_form, round(p_unit_price, 2), coalesce(p_low_stock_limit, 15))
        returning id into v_med_id;
        v_action_type := 'added';
    else
        update public.medications
        set generic_name = v_name,
            dosage_form = v_form,
            unit_price = round(p_unit_price, 2),
            low_stock_limit = coalesce(p_low_stock_limit, low_stock_limit)
        where id = v_med_id;
    end if;

    select mb.* into v_active_batch
    from public.medication_batches mb
    where mb.medication_id = v_med_id
      and mb.status = 'Active'
    for update of mb;

    if found then
        if v_active_batch.batch_no = v_batch then
            v_delta := p_stock_qty - v_active_batch.stock_qty;
            update public.medication_batches
            set stock_qty = p_stock_qty,
                expiry_date = p_expiry_date
            where id = v_active_batch.id;
            v_new_batch_id := v_active_batch.id;
        else
            update public.medication_batches
            set status = 'Superseded'
            where id = v_active_batch.id;

            insert into public.medication_batches (medication_id, batch_no, stock_qty, expiry_date, status)
            values (v_med_id, v_batch, p_stock_qty, p_expiry_date, 'Active')
            returning id into v_new_batch_id;
            v_delta := p_stock_qty;
        end if;
    else
        insert into public.medication_batches (medication_id, batch_no, stock_qty, expiry_date, status)
        values (v_med_id, v_batch, p_stock_qty, p_expiry_date, 'Active')
        returning id into v_new_batch_id;
        v_delta := p_stock_qty;
        v_action_type := 'added';
    end if;

    if v_delta <> 0 then
        insert into public.stock_movements (batch_id, movement_type, qty_delta, balance_after, note, performed_by)
        values (
            v_new_batch_id,
            v_movement,
            v_delta,
            p_stock_qty,
            v_movement || ' for ' || v_code || ' (' || v_batch || ')',
            (select auth.uid())
        );
    end if;

    return jsonb_build_object(
        'medication_id', v_med_id,
        'batch_id', v_new_batch_id,
        'drug_code', v_code,
        'action', v_action_type
    );
end;
$$;

create or replace function public.import_pharmacy_csv_batch(p_rows jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_row jsonb;
    v_res jsonb;
    v_imported integer := 0;
    v_added integer := 0;
    v_updated integer := 0;
begin
    if v_role not in ('Hospital Administrator', 'Hospital Pharmacist') then
        raise exception 'Access denied: % cannot import pharmacy inventory', coalesce(v_role, 'unauthenticated');
    end if;

    if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
        raise exception 'CSV import payload must be a non-empty JSON array';
    end if;

    for v_row in select * from jsonb_array_elements(p_rows)
    loop
        v_res := public.upsert_medication_stock(
            v_row->>'drug_code',
            v_row->>'batch_no',
            v_row->>'generic_name',
            v_row->>'dosage_form',
            (v_row->>'unit_price')::numeric,
            (v_row->>'stock_qty')::integer,
            (v_row->>'expiry_date')::date,
            null,
            'CSV_RESTOCK'
        );
        v_imported := v_imported + 1;
        if v_res->>'action' = 'added' then
            v_added := v_added + 1;
        else
            v_updated := v_updated + 1;
        end if;
    end loop;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'IMPORT_PHARMACY_CSV',
        'medication_batch',
        'bulk',
        jsonb_build_object('imported', v_imported, 'added', v_added, 'updated', v_updated)
    );

    return jsonb_build_object('imported', v_imported, 'added', v_added, 'updated', v_updated);
end;
$$;

create or replace function public.dispose_expired_batch(p_drug_code text)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_code text := upper(trim(coalesce(p_drug_code, '')));
    v_batch record;
    v_days_left integer;
begin
    if v_role not in ('Hospital Administrator', 'Hospital Pharmacist') then
        raise exception 'Access denied: % cannot dispose expired batches', coalesce(v_role, 'unauthenticated');
    end if;

    select
        mb.id as batch_id,
        mb.batch_no,
        mb.stock_qty,
        mb.expiry_date,
        m.id as medication_id,
        m.drug_code,
        m.generic_name,
        m.dosage_form
    into v_batch
    from public.medications m
    join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
    where upper(m.drug_code) = v_code
    for update of mb;

    if not found then
        raise exception 'No active batch found for %', v_code;
    end if;

    v_days_left := (v_batch.expiry_date - current_date)::integer;
    if v_days_left > 30 then
        raise exception 'Only expired or <=30-day blocked batches can be disposed (% has % days remaining)',
            v_batch.drug_code, v_days_left;
    end if;

    update public.medication_batches
    set status = 'Disposed',
        stock_qty = 0,
        disposed_at = now(),
        disposed_by = (select auth.uid())
    where id = v_batch.batch_id;

    if v_batch.stock_qty > 0 then
        insert into public.stock_movements (batch_id, movement_type, qty_delta, balance_after, note, performed_by)
        values (
            v_batch.batch_id,
            'EXPIRED_DISPOSAL',
            -v_batch.stock_qty,
            0,
            'Quarantined expired batch ' || v_batch.batch_no || ' (Exp: ' || v_batch.expiry_date || ')',
            (select auth.uid())
        );
    end if;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'DISPOSE_EXPIRED_BATCH',
        'medication_batch',
        v_batch.batch_id::text,
        jsonb_build_object(
            'drug_code', v_batch.drug_code,
            'batch_no', v_batch.batch_no,
            'qty_disposed', v_batch.stock_qty,
            'expiry_date', v_batch.expiry_date
        )
    );

    return jsonb_build_object(
        'batch_id', v_batch.batch_id,
        'drug_code', v_batch.drug_code,
        'batch_no', v_batch.batch_no,
        'qty_disposed', v_batch.stock_qty
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. RPCs: Billing Stay Days, Settlement & Promissory Note Payment
-- ----------------------------------------------------------------------------
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

    -- Update without RETURNING so Billing Officer RLS on Paid rows does not conflict
    update public.billing_ledgers
    set status = p_payment_type,
        or_number = v_or_number,
        room_cost = v_room_cost,
        doctor_cost = v_doctor_cost,
        pharmacy_cost = v_pharmacy_cost,
        gross_subtotal = v_gross,
        discount_amount = v_discount,
        surcharge_amount = v_surcharge,
        settled_total = v_final_total,
        ward_released = v_ward_released,
        issued_at = v_now,
        issued_by = (select auth.uid()),
        issued_by_role = v_role,
        paid_at = case when p_payment_type = 'Paid' then v_now else null end,
        paid_by = case when p_payment_type = 'Paid' then (select auth.uid()) else null end,
        paid_by_role = case when p_payment_type = 'Paid' then v_role else null end
    where id = v_ledger.id;

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

    -- Preserve issued_at / issued_by / issued_by_role untouched; record paid_* fields without RETURNING
    update public.billing_ledgers
    set status = 'Paid',
        paid_at = v_now,
        paid_by = (select auth.uid()),
        paid_by_role = v_role
    where id = v_ledger.id;

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

-- ----------------------------------------------------------------------------
-- 8. RPCs: Settlement History Admin Override Grant / Revoke
-- ----------------------------------------------------------------------------
create or replace function public.grant_history_override(
    p_target_staff_id uuid,
    p_duration_minutes integer default 30
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_target record;
    v_minutes integer := greatest(1, least(240, coalesce(p_duration_minutes, 30)));
    v_override_id bigint;
    v_expires_at timestamptz;
begin
    if not private.is_admin() then
        raise exception 'Admin Authorization Failed: Only a Hospital Administrator can grant Settlement History access';
    end if;

    select sp.id, sp.username, sp.role
    into v_target
    from public.staff_profiles sp
    where sp.id = p_target_staff_id and sp.is_active = true;

    if not found then
        raise exception 'Target staff account (%) not found or inactive', p_target_staff_id;
    end if;

    insert into public.history_access_overrides (target_staff_id, granted_by_admin_id, granted_at, expires_at)
    values (p_target_staff_id, (select auth.uid()), now(), now() + make_interval(mins => v_minutes))
    returning id, expires_at into v_override_id, v_expires_at;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'GRANT_HISTORY_OVERRIDE',
        'history_access_override',
        v_override_id::text,
        jsonb_build_object(
            'target_staff_id', p_target_staff_id,
            'target_username', v_target.username,
            'duration_minutes', v_minutes,
            'expires_at', v_expires_at
        )
    );

    return jsonb_build_object('override_id', v_override_id, 'expires_at', v_expires_at);
end;
$$;

create or replace function public.revoke_history_override()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_role text := private.current_staff_role();
    v_revoked_count integer := 0;
begin
    if v_role is null then
        raise exception 'Authentication required';
    end if;

    update public.history_access_overrides
    set revoked_at = now()
    where target_staff_id = (select auth.uid())
      and revoked_at is null;

    get diagnostics v_revoked_count = row_count;

    insert into public.audit_logs (actor_staff_id, actor_role, action, entity_type, entity_id, details)
    values (
        (select auth.uid()),
        v_role,
        'REVOKE_HISTORY_OVERRIDE',
        'history_access_override',
        (select auth.uid())::text,
        jsonb_build_object('revoked_count', v_revoked_count)
    );

    return jsonb_build_object('revoked_count', v_revoked_count);
end;
$$;

-- Restrict execute privileges strictly to authenticated staff
revoke all on function public.get_my_staff_profile() from public, anon;
revoke all on function public.admit_inpatient(text, text, text, bigint, text) from public, anon;
revoke all on function public.book_outpatient_appointment(text, text, text, date) from public, anon;
revoke all on function public.dispense_prescription(bigint, text, jsonb) from public, anon;
revoke all on function public.upsert_medication_stock(text, text, text, text, numeric, integer, date, integer, text) from public, anon;
revoke all on function public.import_pharmacy_csv_batch(jsonb) from public, anon;
revoke all on function public.dispose_expired_batch(text) from public, anon;
revoke all on function public.update_inpatient_stay_days(bigint, integer) from public, anon;
revoke all on function public.settle_billing_ledger(bigint, text, numeric, numeric) from public, anon;
revoke all on function public.settle_promissory_note(bigint) from public, anon;
revoke all on function public.grant_history_override(uuid, integer) from public, anon;
revoke all on function public.revoke_history_override() from public, anon;

grant execute on function public.get_my_staff_profile() to authenticated;
grant execute on function public.admit_inpatient(text, text, text, bigint, text) to authenticated;
grant execute on function public.book_outpatient_appointment(text, text, text, date) to authenticated;
grant execute on function public.dispense_prescription(bigint, text, jsonb) to authenticated;
grant execute on function public.upsert_medication_stock(text, text, text, text, numeric, integer, date, integer, text) to authenticated;
grant execute on function public.import_pharmacy_csv_batch(jsonb) to authenticated;
grant execute on function public.dispose_expired_batch(text) to authenticated;
grant execute on function public.update_inpatient_stay_days(bigint, integer) to authenticated;
grant execute on function public.settle_billing_ledger(bigint, text, numeric, numeric) to authenticated;
grant execute on function public.settle_promissory_note(bigint) to authenticated;
grant execute on function public.grant_history_override(uuid, integer) to authenticated;
grant execute on function public.revoke_history_override() to authenticated;

-- ----------------------------------------------------------------------------
-- 9. Optional Supabase Realtime Publication Wiring
-- ----------------------------------------------------------------------------
do $$
declare
    v_tbl text;
begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        foreach v_tbl in array array['admissions', 'appointments', 'medication_batches', 'billing_ledgers', 'prescription_items']
        loop
            if not exists (
                select 1
                from pg_publication_tables
                where pubname = 'supabase_realtime'
                  and schemaname = 'public'
                  and tablename = v_tbl
            ) then
                execute format('alter publication supabase_realtime add table public.%I', v_tbl);
            end if;
        end loop;
    end if;
end $$;

commit;
