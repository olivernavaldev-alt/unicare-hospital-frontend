/**
 * UNICARE Supabase Backend Adapter
 * Zero-build browser ESM integration using pinned @supabase/supabase-js.
 */
(function initUnicareSupabaseAdapter(globalObj) {
    'use strict';

    const SUPABASE_ESM_URL = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm';

    let _createClient = null;
    let _client = null;
    let _realtimeChannel = null;
    let _refreshTimer = null;
    let _currentProfile = null;

    function getConfig() {
        return globalObj.UNICARE_SUPABASE_CONFIG || {
            url: '',
            publishableKey: '',
            staffEmailDomain: 'unicare.recto.local',
            enableRealtime: true
        };
    }

    function isConfigured() {
        const cfg = getConfig();
        return Boolean(
            cfg &&
            typeof cfg.url === 'string' && cfg.url.trim().startsWith('http') &&
            typeof cfg.publishableKey === 'string' && cfg.publishableKey.trim().length > 10
        );
    }

    function normalizeStaffEmail(input) {
        const raw = String(input || '').trim().toLowerCase();
        if (!raw) return '';
        if (raw.includes('@')) return raw;
        const domain = getConfig().staffEmailDomain || 'unicare.recto.local';
        return `${raw}@${domain}`;
    }

    async function loadCreateClient() {
        if (_createClient) return _createClient;
        if (typeof globalObj.__UNICARE_CREATE_CLIENT__ === 'function') {
            _createClient = globalObj.__UNICARE_CREATE_CLIENT__;
            return _createClient;
        }
        const mod = await import(SUPABASE_ESM_URL);
        _createClient = mod.createClient;
        return _createClient;
    }

    async function getClient() {
        if (!isConfigured()) {
            throw new Error('Supabase credentials are not configured in supabase-config.js');
        }
        if (_client) return _client;
        const cfg = getConfig();
        const createClient = await loadCreateClient();
        _client = createClient(cfg.url.trim(), cfg.publishableKey.trim(), {
            auth: {
                persistSession: true,
                autoRefreshToken: true,
                detectSessionInUrl: false
            }
        });
        return _client;
    }

    async function createEphemeralClient() {
        const cfg = getConfig();
        const createClient = await loadCreateClient();
        return createClient(cfg.url.trim(), cfg.publishableKey.trim(), {
            auth: {
                persistSession: false,
                autoRefreshToken: false,
                detectSessionInUrl: false
            }
        });
    }

    function formatDisplayTimestamp(isoString) {
        if (!isoString) return null;
        const dt = new Date(isoString);
        if (Number.isNaN(dt.getTime())) return String(isoString);
        const d = dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
        const t = dt.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
        return `${d} • ${t}`;
    }

    function formatPesoString(amount) {
        return `₱${Number(amount || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    }

    async function fetchProfile(client) {
        const { data, error } = await client.rpc('get_my_staff_profile');
        if (error) throw new Error(error.message || 'Unable to verify staff profile');
        _currentProfile = data;
        return data;
    }

    async function signIn(usernameOrEmail, password, selectedRole) {
        const client = await getClient();
        const email = normalizeStaffEmail(usernameOrEmail);
        const { data: authData, error: authErr } = await client.auth.signInWithPassword({
            email,
            password
        });
        if (authErr || !authData?.session) {
            throw new Error(authErr?.message || 'Invalid staff credentials');
        }

        const profile = await fetchProfile(client);
        if (selectedRole && profile.role !== selectedRole) {
            await client.auth.signOut();
            _currentProfile = null;
            throw new Error(`Role Mismatch: Account "${profile.username}" is assigned to "${profile.role}", not "${selectedRole}".`);
        }
        return profile;
    }

    async function signOut() {
        if (!isConfigured()) return;
        const client = await getClient();
        if (_realtimeChannel && typeof client.removeChannel === 'function') {
            try { await client.removeChannel(_realtimeChannel); } catch {}
            _realtimeChannel = null;
        }
        await client.auth.signOut();
        _currentProfile = null;
    }

    async function restoreSession() {
        if (!isConfigured()) return null;
        const client = await getClient();
        const { data, error } = await client.auth.getSession();
        if (error || !data?.session) return null;
        return fetchProfile(client);
    }

    function getCurrentProfile() {
        return _currentProfile;
    }

    async function verifyAdminAndGrantHistoryOverride(adminUsernameOrEmail, adminPassword, targetStaffId, durationMinutes = 30) {
        const eph = await createEphemeralClient();
        const email = normalizeStaffEmail(adminUsernameOrEmail);
        const { error: authErr } = await eph.auth.signInWithPassword({ email, password: adminPassword });
        if (authErr) {
            throw new Error(authErr.message || 'Invalid Administrator credentials');
        }
        try {
            const { data, error } = await eph.rpc('grant_history_override', {
                p_target_staff_id: targetStaffId,
                p_duration_minutes: durationMinutes
            });
            if (error) throw new Error(error.message || 'Admin authorization denied');
            return data;
        } finally {
            try { await eph.auth.signOut(); } catch {}
        }
    }

    async function revokeHistoryOverride() {
        const client = await getClient();
        const { data, error } = await client.rpc('revoke_history_override');
        if (error) throw new Error(error.message || 'Failed to revoke history override');
        return data;
    }

    function buildReceiptItemsFromDbRow(row) {
        const items = [];
        const roomCost = Number(row.room_cost || 0);
        const doctorCost = Number(row.doctor_cost || 0);
        if (row.visit_type === 'Inpatient' && roomCost > 0) {
            const days = row.admissions?.stay_days || 1;
            items.push({
                title: 'Inpatient Room Charges',
                subtitle: `${row.origin_label} • ${days} day${days > 1 ? 's' : ''}`,
                amount: roomCost
            });
        }
        if (doctorCost > 0 && row.doctors?.full_name) {
            items.push({
                title: 'Attending Specialist Consultation',
                subtitle: `${row.doctors.full_name} (${row.doctors.specialty})`,
                amount: doctorCost
            });
        }
        (row.prescription_items || []).forEach(pi => {
            items.push({
                title: 'Central Pharmacy Medications',
                subtitle: `${pi.drug_name_snapshot} (${pi.dosage_form_snapshot}) • ${pi.qty} unit${pi.qty > 1 ? 's' : ''} @ ${formatPesoString(pi.unit_price_snapshot)}`,
                amount: Number(pi.subtotal)
            });
        });
        return items;
    }

    async function loadOperationalState() {
        const client = await getClient();
        const profile = await fetchProfile(client);

        const [
            doctorsRes,
            illnessesRes,
            roomsRes,
            activeAdmRes,
            activeAppsRes,
            medsRes,
            ledgersRes
        ] = await Promise.all([
            client.from('doctors').select('id, full_name, specialty, consultation_fee').eq('is_active', true).order('id'),
            client.from('illness_categories').select('category_name, contagious_status').order('category_name'),
            client.from('rooms').select('id, room_code, room_name, ward_type, contagious_status, daily_rate, room_allowed_illnesses(illness_category), beds(id, bed_label, is_active)').order('room_code'),
            client.from('admissions').select('id, bed_id, contagious_status, illness_category, stay_days, admitted_at, patients(full_name)').is('discharged_at', null),
            client.from('appointments').select('id, doctor_id, appointment_date, time_slot, status, doctors(full_name), patients(full_name)').eq('status', 'Active').order('id'),
            client.from('v_active_pharmacy_inventory').select('medication_id, batch_id, drug_code, batch_no, generic_name, dosage_form, unit_price, stock_qty, low_stock_limit, expiry_date'),
            client.from('billing_ledgers').select('id, visit_type, admission_id, appointment_id, walkin_ticket_code, account_label, origin_label, clinical_note, doctor_id, doctor_fee_snapshot, status, or_number, room_cost, doctor_cost, pharmacy_cost, gross_subtotal, discount_amount, surcharge_amount, settled_total, ward_released, issued_at, issued_by_role, paid_at, paid_by_role, created_at, doctors(full_name, specialty), admissions(bed_id, stay_days, contagious_status), prescription_items(id, medication_id, batch_id, drug_name_snapshot, dosage_form_snapshot, qty, unit_price_snapshot, subtotal, medications(drug_code)), payment_events(id, event_type, amount, performed_by_role, created_at)').order('id')
        ]);

        for (const r of [doctorsRes, illnessesRes, roomsRes, activeAdmRes, activeAppsRes, medsRes, ledgersRes]) {
            if (r.error) throw new Error(r.error.message || 'Database query failed');
        }

        const doctors = (doctorsRes.data || []).map(d => ({ name: d.full_name, spec: d.specialty }));
        const doctorFees = {};
        (doctorsRes.data || []).forEach(d => { doctorFees[d.full_name] = Number(d.consultation_fee); });

        const illnessByContagious = { Contagious: [], 'Non-Contagious': [] };
        (illnessesRes.data || []).forEach(ic => {
            if (!illnessByContagious[ic.contagious_status]) illnessByContagious[ic.contagious_status] = [];
            illnessByContagious[ic.contagious_status].push(ic.category_name);
        });

        const occByBedId = new Map();
        (activeAdmRes.data || []).forEach(adm => {
            occByBedId.set(Number(adm.bed_id), {
                patient: adm.patients?.full_name || 'Occupied',
                illness: adm.illness_category
            });
        });

        const rooms = (roomsRes.data || []).map(r => ({
            roomId: r.room_code,
            room: r.room_name,
            type: r.ward_type,
            contagiousStatus: r.contagious_status,
            allowedIllnesses: (r.room_allowed_illnesses || []).map(x => x.illness_category),
            rate: Number(r.daily_rate),
            beds: (r.beds || [])
                .filter(b => b.is_active !== false)
                .sort((a, b) => Number(a.id) - Number(b.id))
                .map(b => {
                    const occ = occByBedId.get(Number(b.id));
                    return {
                        id: Number(b.id),
                        label: b.bed_label,
                        status: occ ? 'Occupied' : 'Available',
                        patient: occ ? occ.patient : null,
                        illness: occ ? occ.illness : null
                    };
                })
        }));

        const medications = (medsRes.data || []).map(m => ({
            id: m.drug_code,
            batch: m.batch_no,
            name: m.generic_name,
            form: m.dosage_form,
            price: Number(m.unit_price),
            stock: Number(m.stock_qty),
            lowLimit: Number(m.low_stock_limit),
            expiry: m.expiry_date,
            isDisposed: false
        }));

        const ledgerIdByAppointmentId = new Map();
        const ledgers = (ledgersRes.data || []).map(row => {
            if (row.appointment_id) ledgerIdByAppointmentId.set(Number(row.appointment_id), Number(row.id));
            const issuedLabel = formatDisplayTimestamp(row.issued_at);
            const paidLabel = formatDisplayTimestamp(row.paid_at);
            const settledLabel = paidLabel || issuedLabel;
            const pharmacyItems = (row.prescription_items || []).map(pi => ({
                drugId: pi.medications?.drug_code || '',
                name: `${pi.drug_name_snapshot} (${pi.dosage_form_snapshot})`,
                qty: Number(pi.qty),
                price: Number(pi.unit_price_snapshot),
                subtotal: Number(pi.subtotal)
            }));

            return {
                id: Number(row.id),
                createdAt: row.created_at,
                visitType: row.visit_type,
                name: row.account_label,
                contagiousStatus: row.admissions?.contagious_status || (row.visit_type === 'Walk-In OTC' ? 'N/A' : 'Non-Contagious'),
                illnessCategory: row.clinical_note,
                bedId: row.admissions?.bed_id ? Number(row.admissions.bed_id) : null,
                originLabel: row.origin_label,
                doctorName: row.doctors?.full_name || null,
                doctorFee: Number(row.doctor_fee_snapshot || 0),
                days: row.admissions?.stay_days ? Number(row.admissions.stay_days) : 0,
                pharmacyItems,
                status: row.status,
                orNumber: row.or_number,
                roomCost: row.room_cost !== null ? Number(row.room_cost) : undefined,
                doctorCost: row.doctor_cost !== null ? Number(row.doctor_cost) : undefined,
                pharmacyCost: row.pharmacy_cost !== null ? Number(row.pharmacy_cost) : undefined,
                grossSubtotal: row.gross_subtotal !== null ? Number(row.gross_subtotal) : undefined,
                discountAmount: row.discount_amount !== null ? Number(row.discount_amount) : undefined,
                surchargeAmount: row.surcharge_amount !== null ? Number(row.surcharge_amount) : undefined,
                settledTotal: row.settled_total !== null ? Number(row.settled_total) : undefined,
                issuedAt: issuedLabel,
                issuedByRole: row.issued_by_role,
                paidAt: paidLabel,
                paidByRole: row.paid_by_role,
                settledAt: settledLabel,
                settledByRole: row.paid_by_role || row.issued_by_role,
                paymentEvents: (row.payment_events || []).map(ev => ({
                    eventType: ev.event_type,
                    amount: Number(ev.amount),
                    at: formatDisplayTimestamp(ev.created_at),
                    byRole: ev.performed_by_role
                })),
                wardReleased: row.ward_released || row.origin_label,
                receiptItems: row.status !== 'Active' ? buildReceiptItemsFromDbRow(row) : undefined
            };
        });

        const appointments = (activeAppsRes.data || []).map(ap => ({
            ledgerId: ledgerIdByAppointmentId.get(Number(ap.id)) || Number(ap.id),
            patient: ap.patients?.full_name || 'Outpatient',
            doctor: ap.doctors?.full_name || '',
            time: ap.time_slot,
            status: ap.status
        }));

        let disposalLog = [];
        if (profile.role === 'Hospital Administrator' || profile.role === 'Hospital Pharmacist') {
            const dispRes = await client
                .from('stock_movements')
                .select('id, qty_delta, note, created_at, medication_batches(batch_no, expiry_date, medications(drug_code, generic_name, dosage_form))')
                .eq('movement_type', 'EXPIRED_DISPOSAL')
                .order('id', { ascending: false });
            if (!dispRes.error && dispRes.data) {
                disposalLog = dispRes.data.map(d => ({
                    id: Number(d.id),
                    drugId: d.medication_batches?.medications?.drug_code || '',
                    batch: d.medication_batches?.batch_no || '',
                    name: d.medication_batches?.medications?.generic_name || '',
                    form: d.medication_batches?.medications?.dosage_form || '',
                    qtyDisposed: Math.abs(Number(d.qty_delta || 0)),
                    expiry: d.medication_batches?.expiry_date || '',
                    disposedAt: formatDisplayTimestamp(d.created_at)
                }));
            }
        }

        return {
            profile,
            doctors,
            doctorFees,
            illnessByContagious,
            rooms,
            medications,
            ledgers,
            appointments,
            disposalLog,
            hasHistoryOverride: Boolean(profile.has_history_override)
        };
    }

    async function callRpc(fnName, params = {}) {
        const client = await getClient();
        const { data, error } = await client.rpc(fnName, params);
        if (error) throw new Error(error.message || `RPC ${fnName} failed`);
        return data;
    }

    async function subscribeRealtime(onRefresh) {
        const cfg = getConfig();
        if (!isConfigured() || cfg.enableRealtime === false || typeof onRefresh !== 'function') return null;
        const client = await getClient();
        if (_realtimeChannel && typeof client.removeChannel === 'function') {
            try { await client.removeChannel(_realtimeChannel); } catch {}
        }
        const scheduleRefresh = () => {
            clearTimeout(_refreshTimer);
            _refreshTimer = setTimeout(() => { onRefresh(); }, 250);
        };
        _realtimeChannel = client
            .channel('unicare-live-ops')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'admissions' }, scheduleRefresh)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'appointments' }, scheduleRefresh)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'medication_batches' }, scheduleRefresh)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'billing_ledgers' }, scheduleRefresh)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'prescription_items' }, scheduleRefresh)
            .subscribe();
        return _realtimeChannel;
    }

    globalObj.UnicareBackend = {
        isConfigured,
        normalizeStaffEmail,
        signIn,
        signOut,
        restoreSession,
        getCurrentProfile,
        loadOperationalState,
        subscribeRealtime,
        verifyAdminAndGrantHistoryOverride,
        revokeHistoryOverride,
        formatDisplayTimestamp,
        admitInpatient: (p) => callRpc('admit_inpatient', {
            p_patient_name: p.patientName,
            p_contagious_status: p.contagiousStatus,
            p_illness_category: p.illnessCategory,
            p_bed_id: p.bedId,
            p_doctor_name: p.doctorName
        }),
        bookAppointment: (p) => callRpc('book_outpatient_appointment', {
            p_patient_name: p.patientName,
            p_doctor_name: p.doctorName,
            p_time_slot: p.timeSlot
        }),
        dispensePrescription: (p) => callRpc('dispense_prescription', {
            p_billing_ledger_id: p.billingLedgerId,
            p_walkin_name: p.walkinName || null,
            p_items: p.items
        }),
        upsertMedicationStock: (p) => callRpc('upsert_medication_stock', {
            p_drug_code: p.drugCode,
            p_batch_no: p.batchNo,
            p_generic_name: p.genericName,
            p_dosage_form: p.dosageForm,
            p_unit_price: p.unitPrice,
            p_stock_qty: p.stockQty,
            p_expiry_date: p.expiryDate,
            p_low_stock_limit: p.lowStockLimit ?? 15,
            p_source: p.source || 'ADD_STOCK'
        }),
        importPharmacyCsvBatch: (rows) => callRpc('import_pharmacy_csv_batch', {
            p_rows: rows
        }),
        disposeExpiredBatch: (drugCode) => callRpc('dispose_expired_batch', {
            p_drug_code: drugCode
        }),
        updateInpatientStayDays: (billingLedgerId, stayDays) => callRpc('update_inpatient_stay_days', {
            p_billing_ledger_id: billingLedgerId,
            p_stay_days: stayDays
        }),
        settleBillingLedger: (billingLedgerId, paymentType, discount = 0, surcharge = 0) => callRpc('settle_billing_ledger', {
            p_billing_ledger_id: billingLedgerId,
            p_payment_type: paymentType,
            p_discount: discount,
            p_surcharge: surcharge
        }),
        settlePromissoryNote: (billingLedgerId) => callRpc('settle_promissory_note', {
            p_billing_ledger_id: billingLedgerId
        })
    };
})(window);
