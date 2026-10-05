import { LightningElement, api } from 'lwc';
import { keepLastWordsTogether } from 'c/antsurancePortalText';

/** What each coverage looks like to a customer: an icon and an everyday example of when it pays. */
const COVERAGES = {
    'Bodily Injury Liability': { icon: 'utility:people', example: 'You run a stop sign and the other driver is hurt: this pays their medical bills and your legal costs.' },
    'Property Damage Liability': { icon: 'utility:shield', example: "You back into a neighbor's parked car: this pays for their repairs." },
    Collision: { icon: 'utility:travel_and_places', example: 'You hit a guardrail on an icy road: this pays to repair your car.' },
    Comprehensive: { icon: 'utility:warning', example: 'A hailstorm dents the roof, or the car is stolen: this pays for it.' },
    'Uninsured Motorist': { icon: 'utility:user', example: 'Someone runs a red light and has no insurance: this pays your medical bills.' },
    'Medical Payments': { icon: 'utility:heart', example: 'A passenger needs stitches after a fender bender: this pays the bill, whoever was at fault.' },
    Dwelling: { icon: 'utility:home', example: 'A kitchen fire damages the walls and cabinets: this pays to rebuild them.' },
    'Personal Property': { icon: 'utility:package', example: 'A burglar takes your laptop and television: this pays to replace them.' },
    'Loss of Use': { icon: 'utility:clock', example: 'Smoke damage means a month in a hotel: this pays the extra cost.' },
    'Personal Liability': { icon: 'utility:people', example: 'A guest slips on your icy steps and sues: this pays their claim and your defense.' },
    'Excess Liability': { icon: 'utility:shield', example: "A serious crash costs more than your auto policy's limit: this pays the rest, up to its own limit." }
};

/** Coverages grouped the way a person thinks about them, by line. Anything not named falls under "Also covered". */
const GROUPS = [
    { match: 'Auto', title: 'If you hurt someone or damage their property', names: ['Bodily Injury Liability', 'Property Damage Liability'] },
    { match: 'Auto', title: 'If your car is damaged', names: ['Collision', 'Comprehensive'] },
    { match: 'Auto', title: 'If you or your passengers are hurt', names: ['Uninsured Motorist', 'Medical Payments'] },
    { match: 'Home', title: 'Your home and belongings', names: ['Dwelling', 'Personal Property'] },
    { match: 'Home', title: 'If you have to move out, or someone is hurt', names: ['Loss of Use', 'Personal Liability', 'Medical Payments'] },
    { match: 'Renters', title: 'Your belongings', names: ['Personal Property', 'Loss of Use'] },
    { match: 'Renters', title: 'If someone is hurt in your home', names: ['Personal Liability', 'Medical Payments'] },
    { match: 'Umbrella', title: 'Extra protection above your other policies', names: ['Excess Liability'] }
];

/** What changes a policy, grouped by what each change does to the customer. Each group has its own icon and tint. */
const CHANGE_GROUPS = [
    { key: 'added', label: 'Added cover', icon: 'utility:add', tone: 'added' },
    { key: 'excluded', label: 'Not covered', icon: 'utility:ban', tone: 'excluded' },
    { key: 'discount', label: 'Discounts', icon: 'utility:percent', tone: 'discount' },
    { key: 'terms', label: 'Other terms', icon: 'utility:file', tone: 'terms' }
];

/** One short sentence for each change, in a customer's words. A function is given the stored description to pull a name or a figure from. */
/** An endorsement by a name a customer would use. The form's own name is shown beside it in gray. */
const CHANGE_TITLES = {
    'Water Backup and Sump Overflow': 'Water backup cover',
    'Earth Movement Exclusion': 'Earthquakes and sinkholes',
    'Protective Device Discount': 'Alarm discount',
    'Mortgagee Clause': 'Your mortgage lender',
    'Loss Payable Clause': 'Your car lender',
    'Rental Reimbursement': 'A rental car while yours is repaired',
    'Roadside Assistance': 'Roadside help',
    'Multi-Policy Discount': 'Discount for more than one policy'
};

/**
 * A limit as two short lines: the amount, then what it is measured by.
 * @param {string} words A limit in words, such as "Up to $485,000, at the cost to repair or replace"
 * @returns {string[]} The amount line and the basis line (empty when there is none)
 */
function splitLimit(words) {
    if (!words) {
        return ['', ''];
    }
    const amount = /^(Up to \$[\d,]*\d),? (.+)$/.exec(words);
    if (amount) {
        return [amount[1], amount[2]];
    }
    const comma = words.indexOf(', ');
    return comma > 0 ? [words.slice(0, comma), words.slice(comma + 2)] : [words, ''];
}

const CHANGE_WORDS = {
    'Rental Reimbursement': (text) => {
        const found = /\$(\d+) a day for up to (\d+) days/.exec(text ?? '');
        return found ? `A rental car while yours is being repaired, up to $${found[1]} a day for ${found[2]} days.` : 'A rental car while yours is being repaired after a claim.';
    },
    'Roadside Assistance': 'Towing, jump starts, lockout and flat tire help, up to four calls a term.',
    'Towing and Rental': 'Towing after a breakdown or crash, and a rental while the vehicle is repaired.',
    'Water Backup and Sump Overflow': 'Water that backs up through a sewer, a drain or your sump pump.',
    'Equipment Breakdown': 'Repairs when your furnace, air conditioning or a major appliance breaks down.',
    'Service Line': 'Repairs to the buried water, sewer and power lines on your property.',
    'Scheduled Personal Property': 'Named valuables, such as jewelry, covered for their full value.',
    'Identity Theft Expense': 'The cost of putting things right after someone steals your identity.',
    'Excess Uninsured Motorist': 'Extra cover when the driver at fault has too little insurance.',
    'Earth Movement Exclusion': 'Damage from earthquake, landslide, sinkhole or settling.',
    'Multi-Policy Discount': 'A lower price because you have more than one policy with us.',
    'Paid in Full Discount': 'A lower price for paying for the year in one go.',
    'Paperless and Autopay Discount': 'A lower price for paperless documents and automatic payments.',
    'Safe Driving Program Discount': 'A lower price for safe driving, measured by the app.',
    'Good Student Discount': 'A lower price for a student driver with good grades.',
    'Protective Device Discount': 'A lower price for your monitored burglar and fire alarm.',
    'Mortgagee Clause': (text) => {
        const found = /Names (.+?) as mortgagee/.exec(text ?? '');
        return found ? `Your lender, ${found[1]}, is paid alongside you on a home claim.` : 'Your mortgage lender is paid alongside you on a home claim.';
    },
    'Loss Payable Clause': (text) => {
        const found = /insured and (.+?)\./.exec(text ?? '');
        return found ? `Your lender, ${found[1]}, is paid alongside you if the car is a total loss.` : 'Your lender is paid alongside you if the car is a total loss.';
    }
};

const LINE_ICONS = [
    ['Auto', 'utility:travel_and_places'],
    ['Home', 'utility:home'],
    ['Renters', 'utility:home'],
    ['Umbrella', 'utility:shield']
];

/**
 * A policy's own page: what it is at a glance, what it covers as cards grouped the way a person thinks,
 * who and what is on it, its extras, and three things worth knowing. It raises `open` to go somewhere
 * (file a claim, add a driver) and `ask` to put a question to Claude.
 */
export default class AntsurancePortalPolicy extends LightningElement {
    policyRecord;
    pointedSection;
    activeTab = 'covered';

    /** The policy to show. A different policy starts on its first tab. */
    @api
    get policy() {
        return this.policyRecord;
    }
    set policy(value) {
        if (value?.id !== this.policyRecord?.id) {
            this.activeTab = 'covered';
        }
        this.policyRecord = value;
    }

    /** A section Claude is pointing at: coverages, people, items or extras. It is outlined and brought into view. */
    @api
    get pointed() {
        return this.pointedSection;
    }
    set pointed(value) {
        this.pointedSection = value;
        if (value) {
            // Open the tab the section is on, then bring it into view.
            const tab = { coverages: 'covered', people: 'people', items: 'people', extras: 'changes', documents: 'documents', bill: 'bill' }[value];
            if (tab) {
                this.activeTab = tab;
            }
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.template.querySelector(`[data-section="${value}"]`)?.scrollIntoView({ block: 'center' }), 120);
        }
    }

    // ------------------------------------------------------------------------------- tabs

    /** The parts of the policy, each with how much is in it. A part with nothing in it has no tab. */
    get tabs() {
        const all = [
            { name: 'covered', label: 'Covered', count: (this.policy?.coverages ?? []).length },
            { name: 'people', label: 'People and property', count: this.people.length + this.items.length },
            { name: 'changes', label: 'Changes', count: (this.policy?.extras ?? []).length },
            { name: 'documents', label: 'Documents', count: this.documentCount },
            // A bill is one thing, so its tab carries no count.
            { name: 'bill', label: 'Your bill', count: this.policy?.bill ? 1 : 0, plain: true },
            { name: 'know', label: 'Good to know', count: this.goodToKnow.length }
        ].filter((tab) => tab.count > 0);
        const shown = all.some((tab) => tab.name === this.activeTab) ? this.activeTab : all[0]?.name;
        return all.map((tab) => ({
            ...tab,
            selected: tab.name === shown,
            showCount: !tab.plain,
            ariaSelected: tab.name === shown ? 'true' : 'false',
            className: tab.name === shown ? 'c-tabs__tab c-tabs__tab_selected' : 'c-tabs__tab'
        }));
    }

    get shownTab() {
        return this.tabs.find((tab) => tab.selected);
    }

    get shownLabel() {
        return this.shownTab?.label;
    }

    get showCovered() {
        return this.shownTab?.name === 'covered';
    }
    get showPeople() {
        return this.shownTab?.name === 'people';
    }
    get showChanges() {
        return this.shownTab?.name === 'changes';
    }
    get showKnow() {
        return this.shownTab?.name === 'know';
    }
    get showDocuments() {
        return this.shownTab?.name === 'documents';
    }
    get showBill() {
        return this.shownTab?.name === 'bill';
    }

    /** A policy in force has a declarations page, and an auto policy with a vehicle on it has ID cards too. */
    get documentCount() {
        if (!this.policy?.inForce) {
            return 0;
        }
        return this.line.includes('Auto') && (this.policy.items ?? []).some((item) => item.kind === 'Vehicle') ? 2 : 1;
    }

    /** The bill as rows: what is due next first, then what has been paid, then how it is billed. */
    get billRows() {
        const bill = this.policy?.bill;
        if (!bill) {
            return [];
        }
        return [
            { key: 'next', icon: 'utility:event', title: 'Next payment', text: bill.nextDue, tone: bill.isBehind ? 'c-icon c-icon_small c-tone_watch' : 'c-icon c-icon_small' },
            { key: 'paid', icon: 'utility:check', title: 'Paid so far this term', text: bill.paidSoFar, tone: 'c-icon c-icon_small c-tone_discount' },
            { key: 'how', icon: 'utility:moneybag', title: bill.headline, text: bill.schedule, tone: 'c-icon c-icon_small' }
        ].filter((row) => row.text);
    }

    get billStandingClass() {
        return this.policy?.bill?.isBehind ? 'c-chip c-chip_watch' : 'c-chip c-chip_good';
    }

    get billChanges() {
        return (this.policy?.bill?.changes ?? []).map((change, index) => {
            const saves = (change.amountText ?? '').startsWith('-');
            // The same plain names as the Changes tab.
            return { ...change, label: CHANGE_TITLES[change.label] ?? change.label, key: `${index}`, icon: saves ? 'utility:percent' : 'utility:add', tone: saves ? 'c-icon c-icon_small c-tone_discount' : 'c-icon c-icon_small' };
        });
    }

    get hasBillChanges() {
        return this.billChanges.length > 0;
    }

    handleAskBill() {
        this.ask(`Explain my ${this.line.toLowerCase()} bill: what I pay, what is due next, and what has changed the price.`);
    }

    /** Something inside a tab asked to go somewhere: pass it on. */
    handleInnerOpen(event) {
        event.stopPropagation();
        this.go(event.detail.page, event.detail.recordId);
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.name;
    }

    /** Left and right arrows, Home and End move between tabs, as tabs do everywhere. */
    handleTabKey(event) {
        const names = this.tabs.map((tab) => tab.name);
        const at = names.indexOf(event.currentTarget.dataset.name);
        const to = { ArrowRight: (at + 1) % names.length, ArrowLeft: (at - 1 + names.length) % names.length, Home: 0, End: names.length - 1 }[event.key];
        if (to === undefined) {
            return;
        }
        event.preventDefault();
        this.activeTab = names[to];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(`.c-tabs__tab[data-name="${names[to]}"]`)?.focus(), 30);
    }

    get line() {
        return this.policy?.line ?? '';
    }

    get lineIcon() {
        const match = LINE_ICONS.find(([word]) => this.line.includes(word));
        return match ? match[1] : 'utility:shield';
    }

    get statusClass() {
        return this.policy.status === 'Active' ? 'c-chip c-chip_good' : this.policy.status === 'Renewing soon' ? 'c-chip c-chip_watch' : 'c-chip';
    }

    get isAuto() {
        return this.line.includes('Auto') && this.policy.inForce;
    }

    get term() {
        return `${this.policy.startsText} to ${this.policy.endsText}`;
    }

    get premiumLine() {
        return this.policy.monthlyText ? `${this.policy.premiumText} a year, ${this.policy.monthlyText}` : `${this.policy.premiumText} a year`;
    }

    /** When it renews, and the offer if one has been made. */
    get renewal() {
        const policy = this.policy;
        if (!policy.inForce) {
            return undefined;
        }
        return policy.renewalPremiumText
            ? { title: `${policy.renewalPremiumText} a year from ${policy.endsText}`, note: `Your renewal offer, ${policy.renewalChangeText}` }
            : { title: `Renews ${policy.endsText}`, note: 'We will send your renewal offer before then' };
    }

    sectionClass(name) {
        return this.pointedSection === name ? 'c-part c-part_pointed' : 'c-part';
    }

    get coveragesClass() {
        return this.sectionClass('coverages');
    }
    get peopleClass() {
        return this.sectionClass('people');
    }
    get itemsClass() {
        return this.sectionClass('items');
    }
    get extrasClass() {
        return this.sectionClass('extras');
    }

    /** The coverages as groups of cards. */
    get groups() {
        const rows = this.policy?.coverages ?? [];
        const used = new Set();
        const card = (coverage) => {
            used.add(coverage.name);
            const look = COVERAGES[coverage.name] ?? { icon: 'utility:shield' };
            const [limit, basis] = splitLimit(coverage.limitWords);
            return {
                ...coverage,
                limitWords: limit,
                limitBasis: basis,
                key: coverage.name,
                icon: look.icon,
                plainWords: keepLastWordsTogether(coverage.plainWords, true),
                example: keepLastWordsTogether(look.example, true),
                question: `What does ${coverage.name} cover on my ${this.line.toLowerCase()} policy?`
            };
        };
        const groups = GROUPS.filter((group) => this.line.includes(group.match))
            .map((group) => ({ title: group.title, cards: rows.filter((row) => group.names.includes(row.name) && !used.has(row.name)).map(card) }))
            .filter((group) => group.cards.length);
        const rest = rows.filter((row) => !used.has(row.name)).map(card);
        if (rest.length) {
            groups.push({ title: groups.length ? 'Also covered' : 'What you are covered for', cards: rest });
        }
        return groups.map((group) => ({ ...group, key: group.title }));
    }

    get hasCoverages() {
        return this.groups.length > 0;
    }

    /** One row for each person, however many roles they hold on the policy. */
    get people() {
        const byName = new Map();
        (this.policy?.people ?? []).forEach((person) => {
            const entry = byName.get(person.name) ?? { name: person.name, roles: [], relationship: person.relationship };
            if (person.role && !entry.roles.includes(person.role)) {
                // The named insured comes first.
                if (person.role === 'Named Insured') {
                    entry.roles.unshift(person.role);
                } else {
                    entry.roles.push(person.role);
                }
            }
            byName.set(person.name, entry);
        });
        return [...byName.values()].map((entry) => {
            const roles = entry.roles.map((role, index) => (index === 0 ? role.charAt(0) + role.slice(1).toLowerCase() : role.toLowerCase()));
            const about = roles.length > 1 ? `${roles.slice(0, -1).join(', ')} and ${roles[roles.length - 1]}` : (roles[0] ?? '');
            const relation = entry.relationship && entry.relationship !== 'Self' ? entry.relationship.toLowerCase() : '';
            return {
                key: entry.name,
                name: entry.name,
                about: [about, relation].filter(Boolean).join(', '),
                initials: entry.name
                    .split(' ')
                    .map((part) => part.charAt(0))
                    .slice(0, 2)
                    .join('')
                    .toUpperCase()
            };
        });
    }

    get hasPeople() {
        return this.people.length > 0;
    }

    get items() {
        const names = (this.policy?.coverages ?? []).map((row) => row.name);
        const applies = [];
        if (names.some((name) => name.includes('Liability'))) {
            applies.push('liability');
        }
        ['Collision', 'Comprehensive'].forEach((name) => {
            if (names.includes(name)) {
                applies.push(name.toLowerCase());
            }
        });
        const sentence = applies.length > 1 ? `${applies.slice(0, -1).join(', ')} and ${applies[applies.length - 1]}` : applies[0];
        return (this.policy?.items ?? []).map((item, index) => {
            const isVehicle = item.kind === 'Vehicle';
            return {
                key: `${index}`,
                name: item.name,
                icon: isVehicle ? 'utility:travel_and_places' : 'utility:home',
                detail: keepLastWordsTogether(item.detail, true),
                applies: isVehicle && sentence ? `Covered for ${sentence}.` : ''
            };
        });
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get itemsTitle() {
        return this.line.includes('Auto') ? 'Your vehicles' : 'What is insured';
    }

    /** The policy's endorsements as rows, grouped by what they do: added cover, not covered, discounts, other terms. */
    get changeGroups() {
        const rows = (this.policy?.extras ?? []).map((extra, index) => {
            const name = extra.name ?? '';
            let group = 'added';
            if (name.includes('Discount')) {
                group = 'discount';
            } else if (name.includes('Exclusion')) {
                group = 'excluded';
            } else if (name.includes('Mortgagee') || name.includes('Loss Payable') || name.includes('Lienholder')) {
                group = 'terms';
            }
            const known = CHANGE_WORDS[name];
            // An endorsement this page has no sentence for falls back to the first sentence on the record.
            const stored = (extra.plainWords ?? '').split('. ')[0];
            const words = typeof known === 'function' ? known(extra.plainWords) : (known ?? (stored && !stored.endsWith('.') ? `${stored}.` : stored));
            const title = CHANGE_TITLES[name];
            return { key: `${index}`, group, title: title ?? name, formName: title ? name : '', words, price: extra.premiumChangeText };
        });
        return CHANGE_GROUPS.map((group) => ({
            ...group,
            iconClass: `c-icon c-icon_small c-tone_${group.tone}`,
            rows: rows.filter((row) => row.group === group.key)
        })).filter((group) => group.rows.length);
    }

    /** The extras are part of the yearly price already. Said wherever their amounts are listed. */
    get includedNote() {
        const priced = (this.policy?.extras ?? []).some((extra) => extra.premiumChangeText);
        return priced && this.policy?.premiumText ? `Already included in your ${this.policy.premiumText} a year. Nothing here is added to it or taken from it again.` : '';
    }

    get hasExtras() {
        return this.changeGroups.length > 0;
    }

    /** Three things worth knowing, one short sentence each. */
    get goodToKnow() {
        const policy = this.policy;
        const rows = [];
        if (policy.inForce) {
            rows.push({
                key: 'renews',
                icon: 'utility:event',
                title: `It renews on ${policy.endsText}`,
                text: policy.renewalPremiumText ? `Your renewal offer is ${policy.renewalPremiumText} a year, ${policy.renewalChangeText}.` : 'We send your renewal offer before then, so there is time to review it.'
            });
        }
        rows.push({ key: 'change', icon: 'utility:edit', title: 'To change it', text: 'Ask Claude or send a request. Nothing changes until we confirm it with you.' });
        rows.push({
            key: 'accident',
            icon: 'utility:warning',
            title: this.line.includes('Auto') ? 'After an accident' : 'If something happens',
            text: 'Check everyone is safe and call 911 if anyone is hurt, then file a claim here.'
        });
        return rows;
    }

    /** The policy named by what it protects, kept short enough for one line: "Auto policy for your RAV4 and Accord". */
    get title() {
        const policy = this.policy;
        const items = policy.items ?? [];
        if (this.line.includes('Auto') && items.length && items.length <= 3) {
            // "2022 Toyota RAV4" is known by its model.
            const models = items.map((item) => item.name.split(' ').slice(2).join(' ') || item.name);
            const list = models.length > 1 ? `${models.slice(0, -1).join(', ')} and ${models[models.length - 1]}` : models[0];
            return `Auto policy for your ${list}`;
        }
        if ((this.line === 'Homeowners' || this.line === 'Renters') && policy.insured) {
            return `${this.line === 'Renters' ? 'Renters' : 'Home'} policy for ${policy.insured.split(',')[0]}`;
        }
        if (this.line === 'Umbrella') {
            return 'Umbrella policy';
        }
        return policy.plainName;
    }

    /** A second line under the title where the short title leaves something out. */
    get subtitle() {
        return this.line === 'Umbrella' ? 'Extra liability cover over your other policies' : '';
    }

    /** Under the yearly price, a short line each: about what that is a month, then how it is billed and whether payments are up to date. */
    get payNotes() {
        const month = this.policy.monthlyText ? this.policy.monthlyText.charAt(0).toUpperCase() + this.policy.monthlyText.slice(1) : '';
        return [month, this.billingLine].filter(Boolean);
    }

    get billingLine() {
        const policy = this.policy;
        if (!policy.billing) {
            return '';
        }
        const how = { Annual: 'once a year', 'Semi-Annual': 'twice a year', Quarterly: 'every quarter', Monthly: 'monthly' }[policy.billing] ?? policy.billing.toLowerCase();
        const state = { Current: 'payments up to date', 'Paid in Full': 'paid in full' }[policy.payments] ?? (policy.payments ? `payments ${policy.payments.toLowerCase()}` : '');
        return `Billed ${how}${state ? `, ${state}` : ''}`;
    }

    go(page, recordId) {
        this.dispatchEvent(new CustomEvent('open', { detail: { page, recordId } }));
    }

    handleClaim() {
        this.go('newClaim', this.policy.id);
    }

    handleDriver() {
        this.go('addDriver', this.policy.id);
    }

    handleChange() {
        this.go('newRequest', this.policy.id);
    }

    handleAskPolicy() {
        this.ask(`What does my ${this.line.toLowerCase()} policy cover?`);
    }

    handleAskCoverage(event) {
        this.ask(event.currentTarget.dataset.question);
    }

    ask(text) {
        this.dispatchEvent(new CustomEvent('ask', { detail: { text } }));
    }
}
