# UNICARE — Recto Medical Hospital Operations Management System (Frontend Baseline)

A single-page frontend baseline for **UNICARE (Recto Medical)**, ready to be forked or cloned for independent backend integrations.

## Included Files

- `unicare-v2-complete-updated-v14.html` — Main single-file frontend application (HTML, CSS, and client-side JavaScript)
- `unicare-logo.png` — Brand logo asset
- `unicare-mascot.png` — Dashboard mascot asset
- `unicare-sidebar.png` — Sidebar hero background asset

> **Note:** Keep `unicare-logo.png`, `unicare-mascot.png`, and `unicare-sidebar.png` in the **same folder** as `unicare-v2-complete-updated-v14.html` so relative asset paths resolve properly.

## Quick Start

1. Clone this repository (or fork it to your own GitHub account first):
   ```bash
   git clone https://github.com/olivernavaldev-alt/unicare-hospital-frontend.git
   cd unicare-hospital-frontend
   ```
2. Open `unicare-v2-complete-updated-v14.html` directly in your browser, or run a local static server from the project folder:
   - **VS Code:** Right-click `unicare-v2-complete-updated-v14.html` → **Open with Live Server**
   - **Node.js:** `npx serve .`
   - **Python:** `python -m http.server 8000`

## Modules Included

- **Operations Dashboard** — Live hospital KPIs, occupancy overview, pharmacy alerts, and revenue trends
- **Inpatient Wards (IPD)** — Ward/bed management, admissions, and patient tracking
- **Central Pharmacy** — Medication inventory, expiry tracking, CSV import/export, disposal log, and prescription dispensing
- **Outpatient Triage (OPD)** — Appointment queue, doctor slot management, and triage workflows
- **Billing & Discharge** — Itemized billing, discounts/surcharges, promissory notes, settlement history, and discharge processing

## Staff Roles Supported in the UI

- `Hospital Administrator`
- `Front Desk & Admissions Staff`
- `Hospital Pharmacist`
- `Billing & Discharge Officer`

## Backend Integration Note

All application state is currently stored **client-side in memory** inside `unicare-v2-complete-updated-v14.html`. Each team member can fork or clone this baseline repository to wire up their own database and backend architecture.
