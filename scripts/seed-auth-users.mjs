/**
 * Provision the 4 demo Supabase Auth staff accounts and link public.staff_profiles.
 *
 * Usage (PowerShell):
 *   $env:SUPABASE_URL="https://<your-ref>.supabase.co"
 *   $env:SUPABASE_SECRET_KEY="sb_secret_..."
 *   node scripts/seed-auth-users.mjs
 */

const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SECRET_KEY = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const DOMAIN = process.env.STAFF_EMAIL_DOMAIN || 'unicare.recto.local';

if (!SUPABASE_URL || !SECRET_KEY) {
    console.error('Error: Set SUPABASE_URL and SUPABASE_SECRET_KEY (or SUPABASE_SERVICE_ROLE_KEY) in your environment first.');
    process.exit(1);
}

const DEMO_USERS = [
    {
        username: 'admin.recto',
        email: `admin.recto@${DOMAIN}`,
        full_name: 'Recto Hospital Administrator',
        role: 'Hospital Administrator',
        password: process.env.DEMO_ADMIN_PASSWORD || 'UnicareAdmin2026!'
    },
    {
        username: 'frontdesk.01',
        email: `frontdesk.01@${DOMAIN}`,
        full_name: 'Front Desk & Admissions Officer',
        role: 'Front Desk & Admissions Staff',
        password: process.env.DEMO_FRONTDESK_PASSWORD || 'UnicareFront2026!'
    },
    {
        username: 'pharmacist.01',
        email: `pharmacist.01@${DOMAIN}`,
        full_name: 'Central Pharmacy Dispenser',
        role: 'Hospital Pharmacist',
        password: process.env.DEMO_PHARMACIST_PASSWORD || 'UnicarePharm2026!'
    },
    {
        username: 'billing.01',
        email: `billing.01@${DOMAIN}`,
        full_name: 'Billing & Discharge Cashier',
        role: 'Billing & Discharge Officer',
        password: process.env.DEMO_BILLING_PASSWORD || 'UnicareBill2026!'
    }
];

function authHeaders(extra = {}) {
    return {
        apikey: SECRET_KEY,
        Authorization: `Bearer ${SECRET_KEY}`,
        'Content-Type': 'application/json',
        ...extra
    };
}

async function listExistingUsers() {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=200`, {
        headers: authHeaders()
    });
    if (!res.ok) {
        throw new Error(`Failed listing auth users (${res.status}): ${await res.text()}`);
    }
    const body = await res.json();
    return body.users || [];
}

async function ensureAuthUser(user, existingUsers) {
    const existing = existingUsers.find(u => (u.email || '').toLowerCase() === user.email.toLowerCase());
    if (existing) {
        const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${existing.id}`, {
            method: 'PUT',
            headers: authHeaders(),
            body: JSON.stringify({
                password: user.password,
                email_confirm: true,
                app_metadata: { staff_role: user.role, username: user.username }
            })
        });
        if (!res.ok) {
            throw new Error(`Failed updating auth user ${user.email} (${res.status}): ${await res.text()}`);
        }
        return existing.id;
    }

    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
        method: 'POST',
        headers: authHeaders(),
        body: JSON.stringify({
            email: user.email,
            password: user.password,
            email_confirm: true,
            app_metadata: { staff_role: user.role, username: user.username }
        })
    });
    if (!res.ok) {
        throw new Error(`Failed creating auth user ${user.email} (${res.status}): ${await res.text()}`);
    }
    const created = await res.json();
    return created.id;
}

async function upsertStaffProfile(user, userId) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/staff_profiles?on_conflict=id`, {
        method: 'POST',
        headers: authHeaders({ Prefer: 'resolution=merge-duplicates,return=representation' }),
        body: JSON.stringify({
            id: userId,
            username: user.username,
            email: user.email,
            full_name: user.full_name,
            role: user.role,
            is_active: true
        })
    });
    if (!res.ok) {
        throw new Error(`Failed upserting staff_profile for ${user.username} (${res.status}): ${await res.text()}`);
    }
}

async function main() {
    const existingUsers = await listExistingUsers();
    const summary = [];

    for (const user of DEMO_USERS) {
        const userId = await ensureAuthUser(user, existingUsers);
        await upsertStaffProfile(user, userId);
        summary.push({
            Username: user.username,
            Email: user.email,
            Role: user.role,
            Password: user.password,
            UserId: userId
        });
    }

    console.log('\nUNICARE Demo Staff Accounts Provisioned:');
    console.table(summary);
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
