# Patients, Encounters, and Billing Normalization

**Labels:** `wayfinder:grilling`, `resolved`

## Question

Should inpatient admissions, outpatient consultations, walk-in OTC purchases, and invoices remain combined in a single table or be normalized into 3NF entities?

## Resolution

Use **Full 3NF Separation**:
- `patients` (master MRN registry; nullable on anonymous Walk-In OTC ledgers)
- `admissions` (IPD bed allocation with `UNIQUE (bed_id) WHERE discharged_at IS NULL`)
- `appointments` (OPD queue capped at 3 active patients per doctor/slot)
- `billing_ledgers` (exclusivity `CHECK` linking exactly one of `admission_id`, `appointment_id`, or `walkin_ticket_code`, plus accounting `CHECK` constraints)
- `prescription_items` (price & batch snapshots)
- `payment_events` (immutable audit trail separating Promissory Note issuance from full settlement)
