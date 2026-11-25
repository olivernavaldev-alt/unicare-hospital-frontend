-- ============================================================================
-- UNICARE (Recto Medical) — 004_seed.sql
-- Idempotent Initial Seed: Doctors, Illnesses, 10 Rooms, 25 Beds,
-- 30 Essential Medications, 14 IPD, 14 OPD, 2 OTC, 3 Paid, 2 Promissory Notes
-- ============================================================================

begin;

do $$
declare
    v_doc_santos bigint;
    v_doc_cruz bigint;
    v_doc_reyes bigint;
    v_doc_luna bigint;

    v_r_a1 bigint; v_r_a2 bigint; v_r_b1 bigint; v_r_b2 bigint;
    v_r_c1 bigint; v_r_c2 bigint; v_r_c3 bigint;
    v_r_d1 bigint; v_r_d2 bigint; v_r_d3 bigint;

    v_p_id bigint;
    v_adm_id bigint;
    v_app_id bigint;
    v_ldg_id bigint;
    v_or_prefix text := 'OR-' || to_char(current_date, 'YYYY-MMDD') || '-';
    v_med_rec record;

    -- Helper arrays for seeding prescription items & ledgers cleanly
    type_pt record;
begin
    if exists (select 1 from public.doctors) then
        raise notice 'UNICARE seed data already present — skipping 004_seed.sql.';
        return;
    end if;

    -- 1. Doctors
    insert into public.doctors (full_name, specialty, consultation_fee) values
        ('Dr. Emily Santos', 'Cardiology', 600.00),
        ('Dr. Marcus Cruz', 'General Surgery', 750.00),
        ('Dr. Sofia Reyes', 'Pediatrics', 500.00),
        ('Dr. Antonio Luna', 'Internal Medicine', 600.00);

    select id into v_doc_santos from public.doctors where full_name = 'Dr. Emily Santos';
    select id into v_doc_cruz from public.doctors where full_name = 'Dr. Marcus Cruz';
    select id into v_doc_reyes from public.doctors where full_name = 'Dr. Sofia Reyes';
    select id into v_doc_luna from public.doctors where full_name = 'Dr. Antonio Luna';

    -- 2. Illness Categories
    insert into public.illness_categories (category_name, contagious_status, suggested_doctor_id) values
        ('Infectious / Respiratory', 'Contagious', v_doc_luna),
        ('Isolation Critical', 'Contagious', v_doc_luna),
        ('Vector-Borne (Dengue/Viral)', 'Contagious', v_doc_luna),
        ('Cardiovascular Disease', 'Non-Contagious', v_doc_santos),
        ('General Surgery', 'Non-Contagious', v_doc_cruz),
        ('Internal Medicine', 'Non-Contagious', v_doc_luna),
        ('Pediatric Care', 'Non-Contagious', v_doc_reyes),
        ('OB-GYN / Maternity', 'Non-Contagious', v_doc_reyes);

    -- 3. 10 Multi-Bed Rooms
    insert into public.rooms (room_code, room_name, ward_type, contagious_status, daily_rate) values
        ('A1', 'Room A1', 'Isolation ICU', 'Contagious', 3800.00),
        ('A2', 'Room A2', 'Isolation ICU', 'Contagious', 3800.00),
        ('B1', 'Room B1', 'Infectious Isolation Ward', 'Contagious', 2000.00),
        ('B2', 'Room B2', 'Infectious Isolation Ward', 'Contagious', 2000.00),
        ('C1', 'Room C1', 'General Medical & Surgical', 'Non-Contagious', 1500.00),
        ('C2', 'Room C2', 'General Medical & Surgical', 'Non-Contagious', 1500.00),
        ('C3', 'Room C3', 'General Medical & Surgical', 'Non-Contagious', 1500.00),
        ('D1', 'Room D1', 'Pediatrics & Maternity Ward', 'Non-Contagious', 1200.00),
        ('D2', 'Room D2', 'Pediatrics & Maternity Ward', 'Non-Contagious', 1200.00),
        ('D3', 'Room D3', 'Pediatrics & Maternity Ward', 'Non-Contagious', 1200.00);

    select id into v_r_a1 from public.rooms where room_code = 'A1';
    select id into v_r_a2 from public.rooms where room_code = 'A2';
    select id into v_r_b1 from public.rooms where room_code = 'B1';
    select id into v_r_b2 from public.rooms where room_code = 'B2';
    select id into v_r_c1 from public.rooms where room_code = 'C1';
    select id into v_r_c2 from public.rooms where room_code = 'C2';
    select id into v_r_c3 from public.rooms where room_code = 'C3';
    select id into v_r_d1 from public.rooms where room_code = 'D1';
    select id into v_r_d2 from public.rooms where room_code = 'D2';
    select id into v_r_d3 from public.rooms where room_code = 'D3';

    -- 4. Room-to-Illness Wing Mappings
    insert into public.room_allowed_illnesses (room_id, illness_category) values
        (v_r_a1, 'Infectious / Respiratory'), (v_r_a1, 'Isolation Critical'),
        (v_r_a2, 'Infectious / Respiratory'), (v_r_a2, 'Isolation Critical'),
        (v_r_b1, 'Infectious / Respiratory'), (v_r_b1, 'Vector-Borne (Dengue/Viral)'),
        (v_r_b2, 'Infectious / Respiratory'), (v_r_b2, 'Vector-Borne (Dengue/Viral)'),
        (v_r_c1, 'Cardiovascular Disease'), (v_r_c1, 'General Surgery'), (v_r_c1, 'Internal Medicine'),
        (v_r_c2, 'Cardiovascular Disease'), (v_r_c2, 'General Surgery'), (v_r_c2, 'Internal Medicine'),
        (v_r_c3, 'Cardiovascular Disease'), (v_r_c3, 'General Surgery'), (v_r_c3, 'Internal Medicine'),
        (v_r_d1, 'Pediatric Care'), (v_r_d1, 'OB-GYN / Maternity'),
        (v_r_d2, 'Pediatric Care'), (v_r_d2, 'OB-GYN / Maternity'),
        (v_r_d3, 'Pediatric Care'), (v_r_d3, 'OB-GYN / Maternity');

    -- 5. 25 Physical Beds (Explicit IDs matching UI: 101..406)
    insert into public.beds (id, room_id, bed_label) values
        (101, v_r_a1, 'Bed A1-1'), (102, v_r_a1, 'Bed A1-2'),
        (103, v_r_a2, 'Bed A2-1'), (104, v_r_a2, 'Bed A2-2'),
        (201, v_r_b1, 'Bed B1-1'), (202, v_r_b1, 'Bed B1-2'), (203, v_r_b1, 'Bed B1-3'),
        (204, v_r_b2, 'Bed B2-1'), (205, v_r_b2, 'Bed B2-2'), (206, v_r_b2, 'Bed B2-3'),
        (301, v_r_c1, 'Bed C1-1'), (302, v_r_c1, 'Bed C1-2'), (303, v_r_c1, 'Bed C1-3'),
        (304, v_r_c2, 'Bed C2-1'), (305, v_r_c2, 'Bed C2-2'), (306, v_r_c2, 'Bed C2-3'),
        (307, v_r_c3, 'Bed C3-1'), (308, v_r_c3, 'Bed C3-2'), (309, v_r_c3, 'Bed C3-3'),
        (401, v_r_d1, 'Bed D1-1'), (402, v_r_d1, 'Bed D1-2'),
        (403, v_r_d2, 'Bed D2-1'), (404, v_r_d2, 'Bed D2-2'),
        (405, v_r_d3, 'Bed D3-1'), (406, v_r_d3, 'Bed D3-2');

    perform setval(pg_get_serial_sequence('public.beds', 'id'), 406, true);

    -- 6. 30 Essential Philippine Medications & Active Batches
    create temporary table _seed_meds (
        drug_code text, batch_no text, generic_name text, dosage_form text,
        unit_price numeric(10,2), stock_qty integer, low_limit integer, expiry_date date
    ) on commit drop;

    insert into _seed_meds values
        ('DRUG-001', 'B2026-01', 'Paracetamol', '500mg tablet', 1.75, 250, 30, date '2027-05-15'),
        ('DRUG-002', 'B2026-02', 'Paracetamol', 'IV 1g/100mL bottle', 120.00, 45, 10, (current_date + interval '48 days')::date),
        ('DRUG-003', 'B2026-03', 'Amoxicillin', '500mg capsule', 6.00, 180, 25, (current_date + interval '185 days')::date),
        ('DRUG-004', 'B2026-04', 'Amoxicillin-Clavulanate', '625mg tablet', 32.00, 12, 15, date '2027-08-11'),
        ('DRUG-005', 'B2026-05', 'Ceftriaxone', '1g vial (IV)', 65.00, 60, 15, (current_date + interval '18 days')::date),
        ('DRUG-006', 'B2026-06', 'Metronidazole', '500mg IV bottle', 35.00, 40, 10, date '2027-03-12'),
        ('DRUG-007', 'B2026-07', 'Ciprofloxacin', '500mg tablet', 7.50, 95, 20, date '2027-11-01'),
        ('DRUG-008', 'B2026-08', 'Omeprazole', '40mg vial (IV)', 90.00, 30, 10, date '2027-04-18'),
        ('DRUG-009', 'B2026-09', 'Ranitidine / Famotidine', '20mg injection ampule', 15.00, 50, 15, date '2027-02-22'),
        ('DRUG-010', 'B2026-10', 'Metformin', '500mg tablet', 3.00, 300, 50, date '2028-01-01'),
        ('DRUG-011', 'B2026-11', 'Losartan', '50mg tablet', 6.00, 220, 40, date '2027-09-14'),
        ('DRUG-012', 'B2026-12', 'Amlodipine', '5mg tablet', 3.50, 190, 30, date '2027-06-30'),
        ('DRUG-013', 'B2026-13', 'Furosemide', '20mg/2mL ampule', 11.00, 70, 15, date '2027-07-19'),
        ('DRUG-014', 'B2026-14', 'Insulin Regular', '100IU/mL 10mL vial', 350.00, 15, 10, (current_date + interval '38 days')::date),
        ('DRUG-015', 'B2026-15', 'Insulin NPH', '100IU/mL 10mL vial', 350.00, 7, 10, date '2027-03-01'),
        ('DRUG-016', 'B2026-16', 'Salbutamol', 'Nebule 2.5mg/2.5mL', 11.00, 140, 25, date '2027-10-05'),
        ('DRUG-017', 'B2026-17', 'Hydrocortisone', '100mg vial (IV)', 60.00, 35, 10, date '2027-05-20'),
        ('DRUG-018', 'B2026-18', 'Dexamethasone', '4mg/mL ampule', 15.00, 85, 20, date '2027-08-08'),
        ('DRUG-019', 'B2026-19', 'Tramadol', '50mg/mL ampule', 22.00, 40, 10, date '2027-12-12'),
        ('DRUG-020', 'B2026-20', 'Morphine Sulfate', '10mg/mL ampule', 45.00, 25, 10, date '2027-04-04'),
        ('DRUG-021', 'B2026-21', 'Diazepam', '5mg/mL ampule', 20.00, 30, 10, (current_date - interval '5 days')::date),
        ('DRUG-022', 'B2026-22', 'Epinephrine (Adrenaline)', '1mg/mL ampule', 37.00, 50, 15, date '2027-02-14'),
        ('DRUG-023', 'B2026-23', '0.9% NaCl (PNSS)', '1L IV fluid bottle', 48.00, 110, 30, date '2028-02-01'),
        ('DRUG-024', 'B2026-24', 'D5W', '1L IV fluid bottle', 48.00, 90, 25, date '2028-02-01'),
        ('DRUG-025', 'B2026-25', 'Lactated Ringer''s', '1L IV fluid bottle', 48.00, 100, 25, date '2028-02-01'),
        ('DRUG-026', 'B2026-26', 'Tranexamic Acid', '500mg/5mL ampule', 35.00, 65, 15, date '2027-09-09'),
        ('DRUG-027', 'B2026-27', 'Vancomycin', '500mg vial (IV)', 350.00, 5, 8, (current_date + interval '215 days')::date),
        ('DRUG-028', 'B2026-28', 'Meropenem', '1g vial (IV)', 600.00, 4, 8, date '2027-06-15'),
        ('DRUG-029', 'B2026-29', 'Oxytocin', '10IU/mL ampule', 22.00, 45, 10, date '2027-03-30'),
        ('DRUG-030', 'B2026-30', 'Magnesium Sulfate', '50% 2mL ampule', 22.00, 55, 15, date '2027-10-10');

    for v_med_rec in select * from _seed_meds loop
        insert into public.medications (drug_code, generic_name, dosage_form, unit_price, low_stock_limit)
        values (v_med_rec.drug_code, v_med_rec.generic_name, v_med_rec.dosage_form, v_med_rec.unit_price, v_med_rec.low_limit)
        returning id into v_adm_id; -- reuse bigint var temporarily for medication_id

        insert into public.medication_batches (medication_id, batch_no, stock_qty, expiry_date, status)
        values (v_adm_id, v_med_rec.batch_no, v_med_rec.stock_qty, v_med_rec.expiry_date, 'Active')
        returning id into v_app_id; -- reuse bigint var temporarily for batch_id

        insert into public.stock_movements (batch_id, movement_type, qty_delta, balance_after, note)
        values (v_app_id, 'INITIAL_SEED', v_med_rec.stock_qty, v_med_rec.stock_qty, 'Initial pharmacy catalog seed');
    end loop;

    -- Helper temporary procedure via inline table for seeding ledgers cleanly
    create temporary table _seed_ipd (
        seq integer, name text, contagious text, illness text, bed_id bigint,
        origin text, doc_id bigint, doc_fee numeric(10,2), days integer, admitted_at timestamptz,
        items jsonb
    ) on commit drop;

    insert into _seed_ipd values
        (1, 'Juan Dela Cruz', 'Contagious', 'Infectious / Respiratory', 101, 'Room A1 • Bed A1-1', v_doc_luna, 600, 3, now() - interval '3 days',
            '[{"code":"DRUG-001","qty":10},{"code":"DRUG-028","qty":2}]'::jsonb),
        (2, 'Roberto Mabini', 'Contagious', 'Isolation Critical', 102, 'Room A1 • Bed A1-2', v_doc_luna, 600, 2, now() - interval '2 days',
            '[{"code":"DRUG-027","qty":2},{"code":"DRUG-023","qty":3}]'::jsonb),
        (3, 'Elena Katigbak', 'Contagious', 'Infectious / Respiratory', 103, 'Room A2 • Bed A2-1', v_doc_luna, 600, 2, now() - interval '2 days',
            '[{"code":"DRUG-016","qty":6},{"code":"DRUG-017","qty":2}]'::jsonb),
        (4, 'Andres Santos', 'Contagious', 'Vector-Borne (Dengue/Viral)', 201, 'Room B1 • Bed B1-1', v_doc_luna, 600, 2, now() - interval '2 days',
            '[{"code":"DRUG-023","qty":2},{"code":"DRUG-001","qty":8}]'::jsonb),
        (5, 'Camille Ocampo', 'Contagious', 'Infectious / Respiratory', 202, 'Room B1 • Bed B1-2', v_doc_luna, 600, 1, now() - interval '1 day',
            '[{"code":"DRUG-004","qty":6}]'::jsonb),
        (6, 'Rafael Jacinto', 'Contagious', 'Vector-Borne (Dengue/Viral)', 204, 'Room B2 • Bed B2-1', v_doc_luna, 600, 3, now() - interval '3 days',
            '[{"code":"DRUG-025","qty":4}]'::jsonb),
        (7, 'Maria Clara', 'Non-Contagious', 'Cardiovascular Disease', 301, 'Room C1 • Bed C1-1', v_doc_santos, 600, 2, now() - interval '2 days',
            '[{"code":"DRUG-011","qty":6},{"code":"DRUG-012","qty":6}]'::jsonb),
        (8, 'Gregorio Del Pilar', 'Non-Contagious', 'General Surgery', 302, 'Room C1 • Bed C1-2', v_doc_cruz, 750, 2, now() - interval '2 days',
            '[{"code":"DRUG-019","qty":3},{"code":"DRUG-026","qty":2}]'::jsonb),
        (9, 'Teresa Magbanua', 'Non-Contagious', 'Internal Medicine', 304, 'Room C2 • Bed C2-1', v_doc_luna, 600, 1, now() - interval '1 day',
            '[{"code":"DRUG-010","qty":10},{"code":"DRUG-008","qty":1}]'::jsonb),
        (10, 'Emilio Aguinaldo', 'Non-Contagious', 'Cardiovascular Disease', 305, 'Room C2 • Bed C2-2', v_doc_santos, 600, 3, now() - interval '3 days',
            '[{"code":"DRUG-013","qty":4},{"code":"DRUG-011","qty":10}]'::jsonb),
        (11, 'Melchora Aquino', 'Non-Contagious', 'Internal Medicine', 307, 'Room C3 • Bed C3-1', v_doc_luna, 600, 2, now() - interval '2 days',
            '[{"code":"DRUG-024","qty":2},{"code":"DRUG-009","qty":2}]'::jsonb),
        (12, 'Baby Mateo Cruz', 'Non-Contagious', 'Pediatric Care', 401, 'Room D1 • Bed D1-1', v_doc_reyes, 500, 2, now() - interval '2 days',
            '[{"code":"DRUG-016","qty":4}]'::jsonb),
        (13, 'Clarissa Silang', 'Non-Contagious', 'OB-GYN / Maternity', 402, 'Room D1 • Bed D1-2', v_doc_reyes, 500, 1, now() - interval '1 day',
            '[{"code":"DRUG-029","qty":2},{"code":"DRUG-030","qty":1}]'::jsonb),
        (14, 'Sofia Tolentino', 'Non-Contagious', 'Pediatric Care', 403, 'Room D2 • Bed D2-1', v_doc_reyes, 500, 1, now() - interval '1 day',
            '[{"code":"DRUG-001","qty":6}]'::jsonb);

    for type_pt in select * from _seed_ipd order by seq loop
        insert into public.patients (full_name) values (type_pt.name) returning id into v_p_id;

        insert into public.admissions (
            patient_id, bed_id, attending_doctor_id, contagious_status, illness_category, stay_days, admitted_at
        )
        values (
            v_p_id, type_pt.bed_id, type_pt.doc_id, type_pt.contagious, type_pt.illness, type_pt.days, type_pt.admitted_at
        )
        returning id into v_adm_id;

        insert into public.billing_ledgers (
            visit_type, patient_id, admission_id, account_label, origin_label, clinical_note,
            doctor_id, doctor_fee_snapshot, status, created_at
        )
        values (
            'Inpatient', v_p_id, v_adm_id, type_pt.name, type_pt.origin, type_pt.illness,
            type_pt.doc_id, type_pt.doc_fee, 'Active', type_pt.admitted_at
        )
        returning id into v_ldg_id;

        insert into public.prescription_items (
            billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot, dispensed_at
        )
        select
            v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, (it->>'qty')::integer, m.unit_price, type_pt.admitted_at
        from jsonb_array_elements(type_pt.items) it
        join public.medications m on m.drug_code = it->>'code'
        join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active';
    end loop;

    -- 7. 14 Active Outpatients
    create temporary table _seed_opd (
        seq integer, name text, doc_id bigint, doc_fee numeric(10,2),
        note text, slot text, items jsonb
    ) on commit drop;

    insert into _seed_opd values
        (15, 'Pedro Penduko', v_doc_santos, 600, 'Cardiology Consultation', '09:00 AM', '[{"code":"DRUG-011","qty":10}]'::jsonb),
        (16, 'Lourdes Villanueva', v_doc_santos, 600, 'Cardiology Consultation', '09:00 AM', '[{"code":"DRUG-012","qty":10}]'::jsonb),
        (17, 'Ramon Magsaysay Jr.', v_doc_santos, 600, 'Cardiology Consultation', '10:00 AM', '[]'::jsonb),
        (18, 'Corazon Bautista', v_doc_santos, 600, 'Cardiology Consultation', '01:00 PM', '[{"code":"DRUG-013","qty":2}]'::jsonb),
        (19, 'Arturo Soriano', v_doc_santos, 600, 'Cardiology Consultation', '03:00 PM', '[]'::jsonb),
        (20, 'Danilo Navarro', v_doc_cruz, 750, 'General Surgery Consultation', '09:00 AM', '[{"code":"DRUG-019","qty":2}]'::jsonb),
        (21, 'Patricia Mendoza', v_doc_cruz, 750, 'General Surgery Consultation', '11:00 AM', '[{"code":"DRUG-003","qty":10}]'::jsonb),
        (22, 'Fernando Poe-Reyes', v_doc_cruz, 750, 'General Surgery Consultation', '02:00 PM', '[]'::jsonb),
        (23, 'Beatriz Laurel', v_doc_cruz, 750, 'General Surgery Consultation', '04:00 PM', '[{"code":"DRUG-026","qty":2}]'::jsonb),
        (24, 'Lucas Hernandez', v_doc_reyes, 500, 'Pediatrics Consultation', '10:00 AM', '[{"code":"DRUG-016","qty":3}]'::jsonb),
        (25, 'Isabella Aquino', v_doc_reyes, 500, 'Pediatrics Consultation', '01:00 PM', '[{"code":"DRUG-001","qty":10}]'::jsonb),
        (26, 'Miguelito Ramos', v_doc_reyes, 500, 'Pediatrics Consultation', '03:00 PM', '[]'::jsonb),
        (27, 'Rosario Castillo', v_doc_luna, 600, 'Internal Medicine Consultation', '11:00 AM', '[{"code":"DRUG-010","qty":20}]'::jsonb),
        (28, 'Ernesto Pascual', v_doc_luna, 600, 'Internal Medicine Consultation', '02:00 PM', '[{"code":"DRUG-007","qty":10}]'::jsonb);

    for type_pt in select * from _seed_opd order by seq loop
        insert into public.patients (full_name) values (type_pt.name) returning id into v_p_id;

        insert into public.appointments (patient_id, doctor_id, appointment_date, time_slot, status, created_at)
        values (v_p_id, type_pt.doc_id, current_date, type_pt.slot, 'Active', now() - ((35 - type_pt.seq) * interval '15 minutes'))
        returning id into v_app_id;

        insert into public.billing_ledgers (
            visit_type, patient_id, appointment_id, account_label, origin_label, clinical_note,
            doctor_id, doctor_fee_snapshot, status, created_at
        )
        values (
            'Outpatient', v_p_id, v_app_id, type_pt.name, 'Triage • ' || type_pt.slot, type_pt.note,
            type_pt.doc_id, type_pt.doc_fee, 'Active', now() - ((35 - type_pt.seq) * interval '15 minutes')
        )
        returning id into v_ldg_id;

        if jsonb_array_length(type_pt.items) > 0 then
            insert into public.prescription_items (
                billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot
            )
            select
                v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, (it->>'qty')::integer, m.unit_price
            from jsonb_array_elements(type_pt.items) it
            join public.medications m on m.drug_code = it->>'code'
            join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active';
        end if;
    end loop;

    -- 8. 2 Active Walk-In OTC Pharmacy Tickets
    insert into public.billing_ledgers (
        visit_type, walkin_ticket_code, account_label, origin_label, clinical_note, doctor_fee_snapshot, status, created_at
    ) values (
        'Walk-In OTC', 'OTC-1001', 'Marites Dizon (OTC-1001)', 'Pharmacy Counter • OTC-1001',
        'Over-the-Counter Pharmacy Purchase', 0, 'Active', now() - interval '30 minutes'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, q.qty, m.unit_price
    from (values ('DRUG-001', 20), ('DRUG-003', 14)) as q(code, qty)
    join public.medications m on m.drug_code = q.code
    join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active';

    insert into public.billing_ledgers (
        visit_type, walkin_ticket_code, account_label, origin_label, clinical_note, doctor_fee_snapshot, status, created_at
    ) values (
        'Walk-In OTC', 'OTC-1002', 'Nestor Gomez (OTC-1002)', 'Pharmacy Counter • OTC-1002',
        'Over-the-Counter Pharmacy Purchase', 0, 'Active', now() - interval '15 minutes'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, q.qty, m.unit_price
    from (values ('DRUG-011', 30), ('DRUG-010', 30)) as q(code, qty)
    join public.medications m on m.drug_code = q.code
    join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active';

    -- 9. 5 Historical Billing Records (3 Paid + 2 Unpaid Promissory Notes)
    -- 9a. Paid IPD: Antonio Luna-Reyes (Bed 308 released)
    insert into public.patients (full_name) values ('Antonio Luna-Reyes') returning id into v_p_id;
    insert into public.admissions (
        patient_id, bed_id, attending_doctor_id, contagious_status, illness_category, stay_days, admitted_at, discharged_at
    ) values (
        v_p_id, 308, v_doc_santos, 'Non-Contagious', 'Cardiovascular Disease', 3, now() - interval '3 days', now() - interval '4 hours'
    ) returning id into v_adm_id;

    insert into public.billing_ledgers (
        visit_type, patient_id, admission_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status, or_number,
        room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
        ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at
    ) values (
        'Inpatient', v_p_id, v_adm_id, 'Antonio Luna-Reyes', 'Room C3 • Bed C3-2', 'Cardiovascular Disease',
        v_doc_santos, 600, 'Paid', v_or_prefix || '01',
        4500, 600, 60, 5160, 500, 0, 4660,
        'Room C3 • Bed C3-2 (General Medical & Surgical → Available)',
        now() - interval '4 hours', 'Billing & Discharge Officer',
        now() - interval '4 hours', 'Billing & Discharge Officer',
        now() - interval '3 days'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, 10, m.unit_price
    from public.medications m join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
    where m.drug_code = 'DRUG-011';

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by_role, created_at)
    values (v_ldg_id, 'SETTLED_PAID', 4660, 'Billing & Discharge Officer', now() - interval '4 hours');

    -- 9b. Paid OPD: Ligaya Flores
    insert into public.patients (full_name) values ('Ligaya Flores') returning id into v_p_id;
    insert into public.appointments (patient_id, doctor_id, appointment_date, time_slot, status, settled_at, created_at)
    values (v_p_id, v_doc_reyes, current_date, '09:00 AM', 'Settled', now() - interval '3 hours', now() - interval '1 day')
    returning id into v_app_id;

    insert into public.billing_ledgers (
        visit_type, patient_id, appointment_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status, or_number,
        room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
        ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at
    ) values (
        'Outpatient', v_p_id, v_app_id, 'Ligaya Flores', 'Triage • 09:00 AM', 'Pediatrics Consultation',
        v_doc_reyes, 500, 'Paid', v_or_prefix || '02',
        0, 500, 44, 544, 0, 0, 544,
        'Triage • 09:00 AM',
        now() - interval '3 hours', 'Billing & Discharge Officer',
        now() - interval '3 hours', 'Billing & Discharge Officer',
        now() - interval '1 day'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, 4, m.unit_price
    from public.medications m join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
    where m.drug_code = 'DRUG-016';

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by_role, created_at)
    values (v_ldg_id, 'SETTLED_PAID', 544, 'Billing & Discharge Officer', now() - interval '3 hours');

    -- 9c. Paid OTC: Vicente Sotto Sr. (OTC-1000)
    insert into public.billing_ledgers (
        visit_type, walkin_ticket_code, account_label, origin_label, clinical_note,
        doctor_fee_snapshot, status, or_number,
        room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
        ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at
    ) values (
        'Walk-In OTC', 'OTC-1000', 'Vicente Sotto Sr. (OTC-1000)', 'Pharmacy Counter • OTC-1000', 'Over-the-Counter Pharmacy Purchase',
        0, 'Paid', v_or_prefix || '03',
        0, 0, 440, 440, 40, 0, 400,
        'Pharmacy Counter • OTC-1000',
        now() - interval '2 hours 30 minutes', 'Hospital Administrator',
        now() - interval '2 hours 30 minutes', 'Hospital Administrator',
        now() - interval '1 day'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, q.qty, m.unit_price
    from (values ('DRUG-014', 1), ('DRUG-010', 30)) as q(code, qty)
    join public.medications m on m.drug_code = q.code
    join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active';

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by_role, created_at)
    values (v_ldg_id, 'SETTLED_PAID', 400, 'Hospital Administrator', now() - interval '2 hours 30 minutes');

    -- 9d. Promissory Note IPD: Marcelo H. Del Pilar (Bed 205 released)
    insert into public.patients (full_name) values ('Marcelo H. Del Pilar') returning id into v_p_id;
    insert into public.admissions (
        patient_id, bed_id, attending_doctor_id, contagious_status, illness_category, stay_days, admitted_at, discharged_at
    ) values (
        v_p_id, 205, v_doc_luna, 'Contagious', 'Vector-Borne (Dengue/Viral)', 2, now() - interval '2 days', now() - interval '2 hours'
    ) returning id into v_adm_id;

    insert into public.billing_ledgers (
        visit_type, patient_id, admission_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status, or_number,
        room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
        ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at
    ) values (
        'Inpatient', v_p_id, v_adm_id, 'Marcelo H. Del Pilar', 'Room B2 • Bed B2-2', 'Vector-Borne (Dengue/Viral)',
        v_doc_luna, 600, 'Promissory Note', v_or_prefix || '04',
        4000, 600, 144, 4744, 300, 150, 4594,
        'Room B2 • Bed B2-2 (Infectious Isolation Ward → Available)',
        now() - interval '2 hours', 'Billing & Discharge Officer',
        null, null,
        now() - interval '2 days'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, 3, m.unit_price
    from public.medications m join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
    where m.drug_code = 'DRUG-023';

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by_role, created_at)
    values (v_ldg_id, 'PROMISSORY_ISSUED', 4594, 'Billing & Discharge Officer', now() - interval '2 hours');

    -- 9e. Promissory Note IPD: Gabriela Mendoza (Bed 405 released)
    insert into public.patients (full_name) values ('Gabriela Mendoza') returning id into v_p_id;
    insert into public.admissions (
        patient_id, bed_id, attending_doctor_id, contagious_status, illness_category, stay_days, admitted_at, discharged_at
    ) values (
        v_p_id, 405, v_doc_reyes, 'Non-Contagious', 'OB-GYN / Maternity', 2, now() - interval '2 days', now() - interval '90 minutes'
    ) returning id into v_adm_id;

    insert into public.billing_ledgers (
        visit_type, patient_id, admission_id, account_label, origin_label, clinical_note,
        doctor_id, doctor_fee_snapshot, status, or_number,
        room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total,
        ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at
    ) values (
        'Inpatient', v_p_id, v_adm_id, 'Gabriela Mendoza', 'Room D3 • Bed D3-1', 'OB-GYN / Maternity',
        v_doc_reyes, 500, 'Promissory Note', v_or_prefix || '05',
        2400, 500, 44, 2944, 200, 0, 2744,
        'Room D3 • Bed D3-1 (Pediatrics & Maternity Ward → Available)',
        now() - interval '90 minutes', 'Billing & Discharge Officer',
        null, null,
        now() - interval '2 days'
    ) returning id into v_ldg_id;

    insert into public.prescription_items (billing_ledger_id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot)
    select v_ldg_id, m.id, mb.id, m.generic_name, m.dosage_form, 2, m.unit_price
    from public.medications m join public.medication_batches mb on mb.medication_id = m.id and mb.status = 'Active'
    where m.drug_code = 'DRUG-029';

    insert into public.payment_events (billing_ledger_id, event_type, amount, performed_by_role, created_at)
    values (v_ldg_id, 'PROMISSORY_ISSUED', 2744, 'Billing & Discharge Officer', now() - interval '90 minutes');

    -- 10. Sync daily receipt counter at 5 so next live settlement receives -06
    insert into public.daily_receipt_counters (receipt_date, last_seq)
    values (current_date, 5)
    on conflict (receipt_date) do update set last_seq = greatest(public.daily_receipt_counters.last_seq, 5);

end $$;

commit;
