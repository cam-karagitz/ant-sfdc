/**
 * The one place that says which icon and tint stand for what. Components import from here so that a
 * homeowners policy, a collision coverage or a driver looks the same wherever it appears: in a card,
 * a related list, a tile or a chip.
 *
 * Every icon is a Lightning Design System utility icon, so they share one style and one weight.
 * A tint is one of four quiet pairs (a soft fill and a readable foreground), named for its color.
 * The tile and tint classes that draw them are in c/antsuranceUiStyles.
 */

const FALLBACK = { name: 'utility:shield', tint: 'sand' };

function icon(name, tint) {
    return { name, tint, tileClass: `c-ui-tile c-ui-tile_${tint}` };
}

function find(table, value, fallback) {
    return (value && table[String(value).trim().toLowerCase()]) || fallback;
}

// ---------- Lines of business ----------

const LINES = {
    'personal auto': icon('utility:transport_light_truck', 'clay'),
    'commercial auto': icon('utility:transport_heavy_truck', 'clay'),
    homeowners: icon('utility:home', 'olive'),
    renters: icon('utility:key', 'olive'),
    umbrella: icon('utility:shield', 'amber'),
    'commercial property': icon('utility:company', 'olive'),
    'general liability': icon('utility:groups', 'amber'),
    'workers compensation': icon('utility:identity', 'sand')
};

/** The icon for a line of business ("Personal Auto", "Homeowners"). */
export function lineIcon(line) {
    return find(LINES, line, icon(FALLBACK.name, FALLBACK.tint));
}

// ---------- Coverages ----------

/**
 * What a coverage protects. Coverages are grouped and drawn by this, because it is how a person
 * reads a policy: what happens if I hurt someone, if my own things are damaged, if I am hurt.
 * `order` is the order the groups are shown in.
 */
const GROUPS = {
    others: { key: 'others', label: 'Injury or damage to others', order: 1, ...icon('utility:groups', 'amber') },
    vehicle: { key: 'vehicle', label: 'Damage to the insured vehicles', order: 2, ...icon('utility:transport_light_truck', 'clay') },
    home: { key: 'home', label: 'The home and what is in it', order: 2, ...icon('utility:home', 'olive') },
    premises: { key: 'premises', label: 'Buildings, contents and income', order: 2, ...icon('utility:company', 'olive') },
    people: { key: 'people', label: 'Injury to the insured and passengers', order: 3, ...icon('utility:user', 'sand') },
    employees: { key: 'employees', label: 'Employees hurt at work', order: 1, ...icon('utility:identity', 'sand') },
    other: { key: 'other', label: 'Other cover', order: 9, ...icon('utility:shield', 'sand') }
};

// A coverage's own name decides its group; its category is the fallback for names not listed.
const COVERAGE_GROUPS = {
    'bodily injury liability': 'others',
    'property damage liability': 'others',
    'personal liability': 'others',
    'excess liability': 'others',
    'each occurrence': 'others',
    'products and completed operations': 'others',
    'combined single limit liability': 'others',
    collision: 'vehicle',
    comprehensive: 'vehicle',
    dwelling: 'home',
    'personal property': 'home',
    'loss of use': 'home',
    building: 'premises',
    'business personal property': 'premises',
    'business income': 'premises',
    'uninsured motorist': 'people',
    'medical payments': 'people',
    'medical expense': 'people',
    'workers compensation (statutory)': 'employees',
    'employers liability': 'employees'
};

const CATEGORY_GROUPS = {
    liability: 'others',
    collision: 'vehicle',
    comprehensive: 'vehicle',
    'medical payments': 'people',
    'uninsured motorist': 'people',
    dwelling: 'home',
    'personal property': 'home',
    'loss of use': 'home',
    'business property': 'premises',
    'business income': 'premises',
    'workers compensation': 'employees'
};

// Coverages that deserve their own picture inside their group.
const COVERAGE_ICONS = {
    'bodily injury liability': 'utility:people',
    'property damage liability': 'utility:groups',
    collision: 'utility:transport_light_truck',
    comprehensive: 'utility:shield',
    'uninsured motorist': 'utility:user',
    'medical payments': 'utility:heart',
    'medical expense': 'utility:heart',
    dwelling: 'utility:home',
    'personal property': 'utility:package',
    'loss of use': 'utility:clock',
    'personal liability': 'utility:people',
    'excess liability': 'utility:shield',
    building: 'utility:company',
    'business personal property': 'utility:package',
    'business income': 'utility:moneybag',
    'each occurrence': 'utility:groups',
    'products and completed operations': 'utility:custom_apps',
    'workers compensation (statutory)': 'utility:identity',
    'employers liability': 'utility:groups',
    'combined single limit liability': 'utility:transport_heavy_truck'
};

/** The group a coverage belongs to: { key, label, order, name, tint, tileClass }. */
export function coverageGroup(coverageName, category) {
    const key = find(COVERAGE_GROUPS, coverageName, undefined) ?? find(CATEGORY_GROUPS, category, 'other');
    return GROUPS[key];
}

/** The icon for one coverage, tinted for the group it belongs to. */
export function coverageIcon(coverageName, category) {
    const group = coverageGroup(coverageName, category);
    return icon(find(COVERAGE_ICONS, coverageName, group.name), group.tint);
}

// How a limit applies, in the words an adjuster or a customer would use.
const BASIS_WORDS = {
    'per person': 'for each person',
    'per occurrence': 'for each occurrence',
    aggregate: 'in total for the term',
    'replacement cost': 'at replacement cost',
    'actual cash value': 'at actual cash value',
    statutory: 'as state law requires'
};

/** "Per Person" as "for each person": how a limit applies, in plain words. */
export function basisWords(limitType) {
    return find(BASIS_WORDS, limitType, limitType ? String(limitType).toLowerCase() : '');
}

// ---------- What is insured ----------

const ASSETS = {
    vehicle: icon('utility:transport_light_truck', 'clay'),
    fleet: icon('utility:transport_heavy_truck', 'clay'),
    dwelling: icon('utility:home', 'olive'),
    'rented residence': icon('utility:key', 'olive'),
    'commercial building': icon('utility:company', 'olive'),
    'business property': icon('utility:package', 'amber'),
    workplace: icon('utility:identity', 'sand'),
    operations: icon('utility:settings', 'sand')
};

/** The icon for an insured asset's type ("Vehicle", "Dwelling"). */
export function assetIcon(assetType) {
    return find(ASSETS, assetType, icon('utility:package', 'sand'));
}

// ---------- People on a policy ----------

const ROLES = {
    'named insured': icon('utility:user', 'clay'),
    'additional insured': icon('utility:adduser', 'amber'),
    'policy contact': icon('utility:call', 'sand'),
    driver: icon('utility:key', 'olive'),
    'excluded driver': icon('utility:ban', 'sand'),
    beneficiary: icon('utility:favorite', 'amber'),
    lienholder: icon('utility:moneybag', 'sand'),
    'certificate holder': icon('utility:contract', 'sand')
};

/** The icon for a person's role on a policy ("Named Insured", "Driver"). */
export function roleIcon(role) {
    return find(ROLES, role, icon('utility:user', 'sand'));
}

// ---------- Claims and requests, sales, quotes, forms ----------

const KINDS = {
    claim: icon('utility:case', 'clay'),
    'service request': icon('utility:edit_form', 'olive'),
    'policy service': icon('utility:edit_form', 'olive'),
    person: icon('utility:user', 'sand'),
    sale: icon('utility:trending', 'amber'),
    quote: icon('utility:contract', 'amber'),
    endorsement: icon('utility:page', 'sand'),
    exclusion: icon('utility:ban', 'clay'),
    'lienholder or mortgagee': icon('utility:moneybag', 'sand'),
    benefit: icon('utility:favorite', 'olive'),
    discount: icon('utility:moneybag', 'olive'),
    policy: icon('utility:shield', 'clay')
};

/** The icon for a kind of record: a claim, a service request, a person, a sale, a quote, a form. */
export function kindIcon(kind) {
    return find(KINDS, kind, icon('utility:record', 'sand'));
}

// ---------- Tasks and files ----------

const TASKS = {
    call: icon('utility:call', 'olive'),
    email: icon('utility:email', 'amber'),
    meeting: icon('utility:event', 'clay')
};

/** The icon for a task, from its type or the first word of its subject. */
export function taskIcon(typeOrSubject) {
    const text = String(typeOrSubject ?? '').trim().toLowerCase();
    const first = text.split(/\s+/)[0];
    return TASKS[text] ?? TASKS[first] ?? icon('utility:task', 'sand');
}

const NOTES = {
    contact: icon('utility:call', 'olive'),
    investigation: icon('utility:search', 'amber'),
    coverage: icon('utility:shield', 'olive'),
    reserve: icon('utility:moneybag', 'clay'),
    payment: icon('utility:moneybag', 'clay'),
    underwriting: icon('utility:edit_form', 'olive'),
    service: icon('utility:edit_form', 'olive'),
    general: icon('utility:note', 'sand')
};

/** The icon for a file note's type ("Contact", "Investigation", "Payment"). */
export function noteIcon(noteType) {
    return find(NOTES, noteType, NOTES.general);
}

const FILES = {
    pdf: icon('utility:page', 'clay'),
    jpg: icon('utility:image', 'olive'),
    jpeg: icon('utility:image', 'olive'),
    png: icon('utility:image', 'olive'),
    gif: icon('utility:image', 'olive'),
    webp: icon('utility:image', 'olive'),
    mp4: icon('utility:video', 'amber'),
    mov: icon('utility:video', 'amber'),
    doc: icon('utility:file', 'sand'),
    docx: icon('utility:file', 'sand'),
    xls: icon('utility:table', 'sand'),
    xlsx: icon('utility:table', 'sand')
};

/** The icon for a file, from its extension or type ("pdf", "JPG"). */
export function fileIcon(extension) {
    return find(FILES, String(extension ?? '').replace('.', ''), icon('utility:file', 'sand'));
}

// ---------- By name, for components configured in metadata ----------

const BY_KIND = { line: lineIcon, coverage: coverageIcon, asset: assetIcon, role: roleIcon, kind: kindIcon, task: taskIcon, file: fileIcon, note: noteIcon };

/**
 * The icon for a value of a named kind, for callers that are told the kind as text:
 * a related list configured with "asset:Asset_Type__c" asks for iconFor('asset', 'Vehicle').
 */
export function iconFor(kind, value) {
    const lookup = BY_KIND[kind];
    return lookup ? lookup(value) : kindIcon(kind);
}
