-- ============================================================================
-- UNICARE (Recto Medical) — verify_dba.sql
-- Non-destructive transactional DBA verification suite (BEGIN ... ROLLBACK)
-- Run in Supabase SQL Editor after full_setup.sql to verify all constraints.
-- ============================================================================

begin;

-- 1. Check: Every public table has RLS enabled
do $$
declare
    v_missing integer;
begin
    select count(*)::integer into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relrowsecurity = false;

    if v_missing > 0 then
        raise exception 'DBA CHECK FAILED: % table(s) in public lack RLS', v_missing;
    end if;
    raise notice '[PASS] All public tables have Row-Level Security enabled.';
end $$;

-- 2. Check: Every public view uses security_invoker = true
do $$
declare
    v_bad_views integer;
begin
    select count(*)::integer into v_bad_views
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'v'
      and not exists (
          select 1
          from unnest(coalesce(c.reloptions, array[]::text[])) opt
          where opt = 'security_invoker=true'
      );

    if v_bad_views > 0 then
        raise exception 'DBA CHECK FAILED: % public view(s) missing security_invoker=true', v_bad_views;
    end if;
    raise notice '[PASS] All public views enforce security_invoker=true.';
end $$;

-- 3. Check: Every Foreign Key column in public is indexed
do $$
declare
    v_unindexed integer;
begin
    select count(*)::integer into v_unindexed
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    join pg_namespace n on n.oid = c.connamespace
    where n.nspname = 'public'
      and c.contype = 'f'
      and not exists (
          select 1
          from pg_index i
          where i.indrelid = c.conrelid
            and i.indisvalid
            and (i.indkey::smallint[])[1] = a.attnum
      );

    if v_unindexed > 0 then
        raise exception 'DBA CHECK FAILED: % foreign key column(s) lack a leading index', v_unindexed;
    end if;
    raise notice '[PASS] All public foreign key columns have leading indexes.';
end $$;

-- 4. Test: Isolation Hard-Lock prevents Contagious patient in Non-Contagious Room C1 (Bed 303)
do $$
declare
    v_pt_id bigint;
    v_doc_id bigint;
begin
    insert into public.patients (full_name) values ('Isolation Test Patient') returning id into v_pt_id;
    select id into v_doc_id from public.doctors limit 1;

    begin
        insert into public.admissions (patient_id, bed_id, attending_doctor_id, contagious_status, illness_category)
        values (v_pt_id, 303, v_doc_id, 'Contagious', 'Infectious / Respiratory');
        raise exception 'DBA CHECK FAILED: Contagious patient was allowed into Non-Contagious bed 303';
    exception when others then
        if sqlerrm not like 'Isolation Hard Block%' then
            raise;
        end if;
        raise notice '[PASS] Isolation hard-block rejected Contagious patient in Room C1.';
    end;
end $$;

-- 5. Test: Active-Bed Partial Unique Index blocks double-booking occupied Bed 101
do $$
declare
    v_pt_id bigint;
    v_doc_id bigint;
begin
    insert into public.patients (full_name) values ('Double Book Test Patient') returning id into v_pt_id;
    select id into v_doc_id from public.doctors limit 1;

    begin
        insert into public.admissions (patient_id, bed_id, attending_doctor_id, contagious_status, illness_category)
        values (v_pt_id, 101, v_doc_id, 'Contagious', 'Infectious / Respiratory');
        raise exception 'DBA CHECK FAILED: Occupied bed 101 allowed duplicate active admission';
    exception when unique_violation then
        raise notice '[PASS] Partial unique index rejected double-booking on Bed 101.';
    end;
end $$;

-- 6. Test: OPD 3/3 slot capacity trigger blocks 4th active consultation
do $$
declare
    v_doc_id bigint;
    v_pt_id bigint;
    i integer;
begin
    select id into v_doc_id from public.doctors where full_name = 'Dr. Sofia Reyes';
    for i in 1..3 loop
        insert into public.patients (full_name) values ('Slot Cap Test ' || i) returning id into v_pt_id;
        insert into public.appointments (patient_id, doctor_id, appointment_date, time_slot, status)
        values (v_pt_id, v_doc_id, current_date + 30, '09:00 AM', 'Active');
    end loop;

    insert into public.patients (full_name) values ('Slot Cap Overflow') returning id into v_pt_id;
    begin
        insert into public.appointments (patient_id, doctor_id, appointment_date, time_slot, status)
        values (v_pt_id, v_doc_id, current_date + 30, '09:00 AM', 'Active');
        raise exception 'DBA CHECK FAILED: Allowed 4th booking in 3/3 OPD slot';
    exception when others then
        if sqlerrm not like 'Scheduling Error%' then
            raise;
        end if;
        raise notice '[PASS] OPD 3/3 slot capacity cap enforced.';
    end;
end $$;

-- 7. Test: Non-negative stock CHECK constraint
do $$
begin
    begin
        update public.medication_batches set stock_qty = -1 where batch_no = 'B2026-01';
        raise exception 'DBA CHECK FAILED: Negative stock_qty allowed';
    exception when check_violation then
        raise notice '[PASS] Non-negative stock_qty CHECK constraint enforced.';
    end;
end $$;

-- 8. Test: Billing accounting equation CHECK constraint rejects invalid discount
do $$
begin
    begin
        insert into public.billing_ledgers (
            visit_type, walkin_ticket_code, account_label, origin_label, status, or_number,
            room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
            issued_at, paid_at
        ) values (
            'Walk-In OTC', 'OTC-BAD-999', 'Bad Math Test', 'Pharmacy Counter', 'Paid', 'OR-BAD-999',
            0, 0, 100, 100, 500, 0, 0, now(), now()
        );
        raise exception 'DBA CHECK FAILED: Invalid discount > gross + surcharge allowed';
    exception when check_violation then
        raise notice '[PASS] Financial accounting equation CHECK constraint enforced.';
    end;
end $$;

-- 9. Test: Soft-disposal retains historical FK integrity
do $$
declare
    v_batch_id bigint;
    v_linked_items integer;
begin
    select mb.id into v_batch_id
    from public.medications m
    join public.medication_batches mb on mb.medication_id = m.id
    where m.drug_code = 'DRUG-014' and mb.status = 'Active';

    update public.medication_batches
    set status = 'Disposed', stock_qty = 0, disposed_at = now()
    where id = v_batch_id;

    select count(*)::integer into v_linked_items
    from public.prescription_items
    where batch_id = v_batch_id;

    if v_linked_items < 1 then
        raise exception 'DBA CHECK FAILED: Historical prescription_items link lost after soft disposal';
    end if;
    raise notice '[PASS] Soft-disposal preserved % historical prescription_items row(s).', v_linked_items;
end $$;

rollback;
