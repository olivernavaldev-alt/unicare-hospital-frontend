# UNICARE — Recto Medical Hospital Operations

Domain vocabulary governing clinical admissions, outpatient triage, central pharmacy supply chain, and unified patient billing at Recto Medical.

## Clinical & Capacity

**Patient**:
An individual receiving inpatient or outpatient clinical care at Recto Medical, identified by a unique medical record number.
_Avoid_: Account, client, buyer

**Ward Room**:
A hospital room with a fixed daily rate, contagious isolation classification, and permitted illness categories.
_Avoid_: Wing, unit, bed slot

**Bed**:
A single physical patient berth inside a ward room that holds at most one active admission at a time.
_Avoid_: Slot, room

**Admission**:
An inpatient stay assigning one patient to a compatible available bed under an attending specialist for a recorded duration in days.
_Avoid_: Visit, check-in, ledger

**Outpatient Consultation**:
A scheduled clinic visit pairing a patient with an attending specialist in a fixed time slot capped at three active consultations per specialist per slot.
_Avoid_: Ticket, walk-in

## Pharmacy Supply Chain

**Medication**:
A catalogued pharmaceutical product defined by generic name, dosage form, unit price, and minimum reorder threshold.
_Avoid_: Batch, stock item

**Medication Batch**:
A tracked physical lot of a medication carrying a batch number, remaining unit count, expiration date, and lifecycle status (`Active`, `Disposed`, or `Superseded`).
_Avoid_: Drug, catalog entry

**Prescription Dispense**:
An atomic transfer of medication units from an active, non-expired batch onto a patient's billing ledger or a new walk-in over-the-counter ticket.
_Avoid_: Basket, sale

**Expired Disposal**:
The quarantine and zeroing of an active medication batch within thirty days of expiry, archived for audit without removing historical batch references.
_Avoid_: Deletion, purge

## Billing & Governance

**Billing Ledger**:
The financial account accumulating room, specialist consultation, and pharmacy charges for exactly one admission, outpatient consultation, or walk-in over-the-counter ticket.
_Avoid_: Receipt, patient, encounter

**Official Receipt**:
An immutable settlement statement issued when a billing ledger closes as paid or under a promissory note, bearing a sequential daily receipt number.
_Avoid_: Invoice, ledger

**Promissory Note**:
A deferred settlement arrangement allowing discharge with an unpaid balance whose issuance timestamp and cashier remain preserved when full payment is later recorded.
_Avoid_: Loan, credit, active bill

**Settlement History Override**:
A time-bound administrative authorization granted by a hospital administrator that allows a billing officer's current session to inspect paid settlement records.
_Avoid_: Login, role switch

**Staff Role**:
The hospital department authority assigned to an authenticated staff member (`Hospital Administrator`, `Front Desk & Admissions Staff`, `Hospital Pharmacist`, or `Billing & Discharge Officer`).
_Avoid_: Permission, username
