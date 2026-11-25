# Pharmacy Catalog, Batches, and Stock Traceability

**Labels:** `wayfinder:grilling`, `resolved`

## Question

How should Central Pharmacy track drug catalog metadata, CSV restocks, expired disposals, and dispensed prescriptions?

## Resolution

Use **`medications` + `medication_batches` + `stock_movements`**:
- `medications` stores catalog identity (`drug_code`, `generic_name`, `dosage_form`, `unit_price`, `low_stock_limit`).
- `medication_batches` tracks physical lots with `UNIQUE (medication_id) WHERE status = 'Active'`, allowing CSV restocks to cleanly mark old lots `Superseded` and expired disposals to mark lots `Disposed` without breaking foreign keys from `prescription_items`.
- `stock_movements` records an immutable ledger of every seed, restock, dispense, and disposal delta.
