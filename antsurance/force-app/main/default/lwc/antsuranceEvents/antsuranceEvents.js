import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import getEvents from '@salesforce/apex/AntsuranceEventController.getEvents';
import getExposure from '@salesforce/apex/AntsuranceEventController.getExposure';
import writePlan from '@salesforce/apex/AntsuranceEventController.writePlan';
import createCallTasks from '@salesforce/apex/AntsuranceEventController.createCallTasks';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';
import { keepTogether, tidyEnding } from 'c/antsuranceText';
import { recall, remember, pageOf } from 'c/antsuranceUiMemory';

const MEMORY = 'event-response:';
const PLACE_PAGE = 5;
const CLAIM_PAGE = 5;
const CALL_PAGE = 2;
const COVER_PAGE = 4;
// The most call tasks made in one go. The server enforces the same number.
const MAX_CALLS = 5;
// How many names the "who do we call" line lists before a plan exists.
const NAMES_SHOWN = 2;
const NO_BREAK_SPACE = '\u00a0';
const KIND_ICONS = {
    Home: { name: 'utility:home', tile: 'c-ui-tile c-ui-tile_olive' },
    Business: { name: 'utility:company', tile: 'c-ui-tile c-ui-tile_amber' },
    Vehicle: { name: 'utility:transport_light_truck', tile: 'c-ui-tile c-ui-tile_clay' },
    Workplace: { name: 'utility:identity', tile: 'c-ui-tile c-ui-tile_sand' }
};
const PERIL_WORDS = { Hail: 'hail', Wind: 'wind', Tornado: 'a tornado', Flood: 'flood' };
const STATUS_CLASS = { Responds: 'c-status c-status_yes', 'Excluded on record': 'c-status c-status_no', 'Not stated on record': 'c-status c-status_open' };
// Plans are not stored. They are held here so leaving the page and coming back in the same visit keeps them.
const PLANS = new Map();

function join(names) {
    if (names.length < 2) {
        return names.join('');
    }
    return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

function count(number, one, many) {
    return `${number} ${number === 1 ? one : many}`;
}

/**
 * The Event response page. For a weather event it shows the area on a map, what is insured inside it,
 * the coverages that respond and the claims so far, all worked out from the records. On request Claude
 * writes a response plan and the first calls to make, which a person can turn into call tasks.
 */
export default class AntsuranceEvents extends NavigationMixin(LightningElement) {
    events;
    eventName;
    exposure;
    errorMessage;
    tab = 'exposure';
    selectedKey;
    showNearby = false;
    lineFilter;
    placePage = 0;
    claimPage = 0;
    earlierPage = 0;
    callPage = 0;
    coverPage = 0;
    plan;
    planError;
    isPlanning = false;
    // The message for each call as the person has edited it, and which calls are chosen, by location key.
    messages = {};
    chosen = {};
    isCreating = false;
    createError;
    created;

    connectedCallback() {
        loadBrandFonts(this);
        document.title = 'Event response | Salesforce';
    }

    @wire(getEvents)
    wiredEvents({ data, error }) {
        if (data) {
            this.events = data;
            const remembered = recall(`${MEMORY}event`, undefined);
            const start = data.find((event) => event.name === remembered) ?? data[0];
            if (start && !this.eventName) {
                this.choose(start.name);
            }
        } else if (error) {
            this.errorMessage = error.body?.message ?? 'The events could not be loaded.';
        }
    }

    @wire(getExposure, { eventName: '$eventName' })
    wiredExposure({ data, error }) {
        if (data) {
            this.exposure = data;
            this.errorMessage = undefined;
        } else if (error) {
            this.exposure = undefined;
            this.errorMessage = error.body?.message ?? 'This event could not be worked out.';
        }
    }

    choose(name) {
        this.eventName = name;
        this.exposure = undefined;
        this.errorMessage = undefined;
        this.selectedKey = undefined;
        this.showNearby = false;
        this.lineFilter = undefined;
        this.placePage = 0;
        this.claimPage = 0;
        this.earlierPage = 0;
        this.callPage = 0;
        this.coverPage = 0;
        this.planError = undefined;
        this.createError = undefined;
        this.created = undefined;
        this.usePlan(PLANS.get(name));
        this.tab = recall(`${MEMORY}tab`, 'exposure');
        remember(`${MEMORY}event`, name);
    }

    usePlan(plan) {
        const messages = {};
        const chosen = {};
        (plan?.calls ?? []).forEach((call) => {
            messages[call.key] = call.message ?? '';
            chosen[call.key] = true;
        });
        this.plan = plan;
        this.messages = messages;
        this.chosen = chosen;
    }

    // ---------- Formatting ----------

    money(amount) {
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount ?? 0);
    }

    shortMoney(amount) {
        const value = amount ?? 0;
        if (value < 100000) {
            return this.money(value);
        }
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, notation: 'compact', maximumFractionDigits: 1 }).format(value);
    }

    day(date) {
        if (!date) {
            return '';
        }
        return new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${date}T00:00:00Z`));
    }

    // ---------- The event ----------

    get isLoading() {
        return !this.errorMessage && (!this.events || (this.eventName && !this.exposure));
    }

    get hasNoEvents() {
        return this.events && this.events.length === 0;
    }

    get eventTabs() {
        return (this.events ?? []).map((event) => ({ value: event.name, label: event.label }));
    }

    get event() {
        return this.exposure?.event ?? (this.events ?? []).find((event) => event.name === this.eventName);
    }

    get perilWord() {
        return PERIL_WORDS[this.event?.peril] ?? 'this event';
    }

    get when() {
        const event = this.event;
        if (!event) {
            return '';
        }
        const ago = event.daysAgo === 0 ? 'Today' : event.daysAgo === 1 ? 'Yesterday' : event.daysAgo > 1 ? `${event.daysAgo} days ago` : '';
        const date = this.day(event.eventDate);
        return ago ? `${ago}, ${date}` : date;
    }

    get happened() {
        return `${this.event?.peril ?? ''}: ${this.when}`;
    }

    get whereAbouts() {
        return this.event?.area ? `Across ${this.event.area}.` : '';
    }

    get happenedDetail() {
        return tidyEnding([this.whereAbouts, this.event?.note].filter(Boolean).join(' '));
    }

    get isEmpty() {
        return this.exposure && this.exposure.locations === 0;
    }

    get hasExposure() {
        return this.exposure && this.exposure.locations > 0;
    }

    get insidePlaces() {
        return (this.exposure?.places ?? []).filter((place) => place.inside);
    }

    get nearbyPlaces() {
        return (this.exposure?.places ?? []).filter((place) => !place.inside);
    }

    /** What is exposed, in a sentence. */
    get exposedLine() {
        const exposure = this.exposure;
        if (!exposure) {
            return '';
        }
        if (exposure.locations === 0) {
            return 'Nothing we insure is inside this area.';
        }
        return `${count(exposure.locations, 'location', 'locations')}, ${this.shortMoney(exposure.insuredValue)} insured`;
    }

    get exposedDetail() {
        const exposure = this.exposure;
        if (!exposure) {
            return '';
        }
        if (exposure.locations === 0) {
            return exposure.nearby > 0 ? `${count(exposure.nearby, 'location is', 'locations are')} within 3 miles of its edge.` : 'None is within 3 miles of its edge either.';
        }
        if (exposure.respondingValue >= exposure.insuredValue) {
            return tidyEnding(`All of it is under a coverage that responds to ${this.perilWord}.`);
        }
        return tidyEnding(`${this.shortMoney(exposure.respondingValue)} of it is under a coverage that responds to ${this.perilWord}.`);
    }

    /** Who to call, in a sentence: Claude's choice once a plan exists, the largest locations before. */
    get callLine() {
        if (!this.hasExposure) {
            return 'Nobody yet.';
        }
        const names = this.plan?.calls?.length
            ? this.plan.calls.map((call) => call.customerName)
            : [...new Set(this.insidePlaces.map((place) => place.customerName))];
        // Each name stays whole, so where the line has to break it breaks between two customers.
        const shown = names.slice(0, NAMES_SHOWN).map((name) => name.replace(/ /g, NO_BREAK_SPACE));
        const rest = names.length - shown.length;
        return rest > 0 ? `${shown.join(', ')} and ${rest}${NO_BREAK_SPACE}more` : join(shown);
    }

    get callDetail() {
        if (!this.hasExposure) {
            return 'There is nobody to call for this event.';
        }
        return this.plan?.calls?.length ? 'Claude’s order, from the plan.' : tidyEnding('The largest insured values first. Claude’s plan puts them in order, with a reason for each.');
    }

    /**
     * One control writes the plan, and it is called the same thing wherever it is: "Write the plan". It
     * sits here, in view from every tab, except on the Plan tab, which carries it itself. Once there is a
     * plan this button goes to the calls.
     */
    get callAction() {
        return this.plan ? 'See the calls' : 'Write the plan';
    }

    get callActionIcon() {
        return this.plan ? undefined : 'utility:sparkles';
    }

    get callActionVariant() {
        return this.plan ? 'neutral' : 'brand';
    }

    get showCallAction() {
        if (!this.hasExposure) {
            return false;
        }
        return this.plan ? !this.isCallsTab : !this.isPlanTab;
    }

    // ---------- The map ----------

    get mapPlaces() {
        return (this.exposure?.places ?? []).map((place) => ({
            key: place.key,
            latitude: place.latitude,
            longitude: place.longitude,
            inside: place.inside,
            kind: place.kind,
            name: place.customerName,
            what: place.what
        }));
    }

    get mapLabel() {
        return `Map of ${this.event?.label ?? 'the event'}, with ${count(this.insidePlaces.length, 'insured location', 'insured locations')} inside its area`;
    }

    get selected() {
        const place = (this.exposure?.places ?? []).find((one) => one.key === this.selectedKey);
        if (!place) {
            return undefined;
        }
        const items = place.items.slice(0, 3).map((item) => ({
            key: item.assetId,
            name: item.name,
            policyId: item.policyId,
            policyName: item.policyName,
            policyUrl: `/lightning/r/Policy__c/${item.policyId}/view`,
            value: item.insuredValue ? this.money(item.insuredValue) : '',
            status: item.coverage ?? 'No property or vehicle cover',
            statusClass: STATUS_CLASS[item.coverage] ?? 'c-status c-status_none'
        }));
        return {
            ...place,
            url: `/lightning/r/Account/${place.customerId}/view`,
            where: place.inside ? `${place.town}, inside the area` : `${place.town}, ${place.milesFromEdge} miles outside the area`,
            value: this.money(place.insuredValue),
            items,
            more: place.items.length > items.length ? `and ${place.items.length - items.length} more` : '',
            contact: [place.contactName, place.contactPhone].filter(Boolean).join(', ')
        };
    }

    // ---------- The panel ----------

    get tabs() {
        const exposure = this.exposure;
        return [
            { value: 'exposure', label: 'Exposure' },
            { value: 'locations', label: 'Locations', count: exposure ? exposure.locations : undefined },
            // The count is of claims since the event, the same number the "Claims since" figure gives. Claims already open are listed apart.
            { value: 'claims', label: 'Claims', count: exposure ? exposure.claimsSince : undefined },
            { value: 'plan', label: 'Plan' },
            { value: 'calls', label: 'Calls', count: this.plan ? this.plan.calls.length : undefined }
        ];
    }

    /**
     * An event with nothing inside it has one thing to say, and the three answers above the map say it.
     * So the map takes the page's width and the panel beside it, whose every tab would be empty, is not drawn.
     */
    get bodyClass() {
        return this.isEmpty ? 'c-body c-body_alone' : 'c-body';
    }

    get panelClass() {
        return this.isEmpty ? 'c-panel c-panel_gone' : 'c-panel';
    }

    // The same event shows no row of tabs, should the panel be drawn.
    get isExposureTab() {
        return this.tab === 'exposure' || this.isEmpty;
    }

    get isLocationsTab() {
        return this.tab === 'locations' && !this.isEmpty;
    }

    get isClaimsTab() {
        return this.tab === 'claims' && !this.isEmpty;
    }

    get isPlanTab() {
        return this.tab === 'plan' && !this.isEmpty;
    }

    get isCallsTab() {
        return this.tab === 'calls' && !this.isEmpty;
    }

    get figures() {
        const exposure = this.exposure;
        return [
            { key: 'locations', label: 'Locations', value: String(exposure.locations), note: exposure.nearby > 0 ? `${exposure.nearby} more just outside` : 'None just outside' },
            { key: 'customers', label: 'Customers', value: String(exposure.customers), note: count(exposure.policies, 'policy', 'policies') },
            {
                key: 'value',
                label: 'Insured value',
                value: this.shortMoney(exposure.insuredValue),
                note: exposure.respondingValue >= exposure.insuredValue ? 'All of it responds' : `${this.shortMoney(exposure.respondingValue)} responds`
            },
            {
                key: 'claims',
                label: 'Claims since',
                value: String(exposure.claimsSince),
                note: exposure.claimsSince === 0 ? 'None reported yet' : `${exposure.claimsSinceRelated} of this kind`
            }
        ].map((figure) => ({ ...figure, title: `Show the list behind ${figure.label.toLowerCase()}` }));
    }

    get expectLine() {
        const exposure = this.exposure;
        if (exposure?.expectedLow === undefined || exposure.expectedLow === null) {
            return undefined;
        }
        if (exposure.expectedLow === 0) {
            return `Expect up to ${count(exposure.expectedHigh, 'claim', 'claims')}`;
        }
        return exposure.expectedLow === exposure.expectedHigh
            ? `Expect about ${count(exposure.expectedHigh, 'claim', 'claims')}`
            : `Expect ${exposure.expectedLow} to ${count(exposure.expectedHigh, 'claim', 'claims')}`;
    }

    get expectBasis() {
        return tidyEnding(this.exposure?.expectedBasis);
    }

    get lineRows() {
        return (this.exposure?.byLine ?? []).map((row) => ({
            ...row,
            icon: lineIcon(row.line),
            policiesText: count(row.policies, 'policy', 'policies'),
            value: row.insuredValue > 0 ? this.shortMoney(row.insuredValue) : '',
            responds:
                row.insuredValue <= 0
                    ? 'no property or vehicle cover'
                    : row.respondingValue >= row.insuredValue
                      ? 'all of it responds'
                      : row.respondingValue > 0
                        ? `${this.shortMoney(row.respondingValue)} responds`
                        : 'none of it responds',
            title: `Show the ${row.line} locations`
        }));
    }

    get coverageRows() {
        return pageOf(this.exposure?.coverages ?? [], this.coverPage, COVER_PAGE).map((row) => ({
            ...row,
            key: `${row.name}|${row.status}`,
            statusClass: STATUS_CLASS[row.status] ?? 'c-status',
            policiesText: count(row.policies, 'policy', 'policies'),
            deductible:
                row.deductibleLow === undefined || row.deductibleLow === null
                    ? 'No deductible recorded'
                    : row.deductibleLow === row.deductibleHigh
                      ? `${this.money(row.deductibleLow)} deductible`
                      : `${this.money(row.deductibleLow)} to ${this.money(row.deductibleHigh)} deductibles`
        }));
    }

    get coverageNotes() {
        return (this.exposure?.coverageNotes ?? []).map((text, index) => ({ key: index, text }));
    }

    get coverageSummary() {
        const rows = this.exposure?.coverages ?? [];
        const yes = rows.filter((row) => row.status === 'Responds').length;
        if (yes === rows.length) {
            return `All ${rows.length} respond to ${this.perilWord}`;
        }
        return `${yes} of ${rows.length} respond to ${this.perilWord}`;
    }

    get coverageCount() {
        return (this.exposure?.coverages ?? []).length;
    }

    get coverPageSize() {
        return COVER_PAGE;
    }

    // ---------- Locations ----------

    get listedPlaces() {
        const places = this.showNearby ? this.nearbyPlaces : this.insidePlaces;
        return this.lineFilter && !this.showNearby ? places.filter((place) => place.lines.includes(this.lineFilter)) : places;
    }

    get placeRows() {
        return pageOf(this.listedPlaces, this.placePage, PLACE_PAGE).map((place) => {
            const icon = KIND_ICONS[place.kind] ?? KIND_ICONS.Workplace;
            const isChosen = place.key === this.selectedKey;
            let cover = 'No property or vehicle cover here';
            if (place.insuredValue > 0) {
                cover =
                    place.respondingValue >= place.insuredValue
                        ? 'Cover responds'
                        : place.respondingValue > 0
                          ? `${this.shortMoney(place.respondingValue)} under cover that responds`
                          : `No cover on record responds to ${this.perilWord}`;
            }
            return {
                key: place.key,
                name: place.customerName,
                about: `${place.what}, ${place.town}`,
                value: place.insuredValue > 0 ? this.money(place.insuredValue) : '',
                cover: place.inside ? cover : `${place.milesFromEdge} miles outside`,
                claims: place.openClaims > 0 ? count(place.openClaims, 'open claim', 'open claims') : '',
                iconName: icon.name,
                tileClass: icon.tile,
                pressed: isChosen ? 'true' : 'false',
                className: `c-place c-ui-open${isChosen ? ' c-place_chosen' : ''}`,
                label: `Show ${place.customerName} on the map`
            };
        });
    }

    get placeTotal() {
        return this.listedPlaces.length;
    }

    get placePageSize() {
        return PLACE_PAGE;
    }

    get hasPlaces() {
        return this.listedPlaces.length > 0;
    }

    get noPlacesText() {
        return this.showNearby ? 'No insured location is within 3 miles of the edge.' : 'No insured location is inside this area.';
    }

    get scopes() {
        return [
            { value: 'inside', label: 'Inside', count: this.insidePlaces.length },
            { value: 'nearby', label: 'Just outside', count: this.nearbyPlaces.length }
        ];
    }

    get scope() {
        return this.showNearby ? 'nearby' : 'inside';
    }

    get lineFilterLabel() {
        return `${this.lineFilter} only`;
    }

    get lineFilterTitle() {
        return `Show every line again, not only ${this.lineFilter}`;
    }

    // ---------- Claims ----------

    claimRow(claim) {
        return {
            ...claim,
            url: `/lightning/r/Case/${claim.claimId}/view`,
            about: [claim.customerName, claim.lossType, claim.lossDate ? `loss ${this.day(claim.lossDate)}` : ''].filter(Boolean).join(', '),
            // A claim since the event says whether its cause is this event's kind. One open before it cannot be from it.
            when: claim.sinceEvent ? (claim.related ? `A kind ${this.perilWord} causes` : `Not a kind ${this.perilWord} causes`) : 'Open before the event',
            whenClass: claim.sinceEvent && claim.related ? 'c-status c-status_yes' : 'c-status c-status_none'
        };
    }

    /** Claims with a loss on or after the day of the event: the ones the tab and the "Claims since" figure count. */
    get sinceClaims() {
        return (this.exposure?.claims ?? []).filter((claim) => claim.sinceEvent);
    }

    /** Claims that were open on these policies before the event, so are not from it. Listed apart, folded. */
    get earlierClaims() {
        return (this.exposure?.claims ?? []).filter((claim) => !claim.sinceEvent);
    }

    get claimRows() {
        return pageOf(this.sinceClaims, this.claimPage, CLAIM_PAGE).map((claim) => this.claimRow(claim));
    }

    get claimTotal() {
        return this.sinceClaims.length;
    }

    get claimPageSize() {
        return CLAIM_PAGE;
    }

    get hasClaims() {
        return this.claimTotal > 0;
    }

    get earlierRows() {
        return pageOf(this.earlierClaims, this.earlierPage, CLAIM_PAGE).map((claim) => this.claimRow(claim));
    }

    get earlierTotal() {
        return this.earlierClaims.length;
    }

    get hasEarlier() {
        return this.earlierTotal > 0;
    }

    handleEarlierPage(event) {
        this.earlierPage = event.detail.page;
    }

    get claimsLine() {
        const exposure = this.exposure;
        if (!exposure) {
            return '';
        }
        const since =
            exposure.claimsSince === 0
                ? `No claim with a loss since ${this.day(exposure.event.eventDate)} has come in from this area.`
                : `${count(exposure.claimsSince, 'claim has', 'claims have')} a loss since ${this.day(exposure.event.eventDate)}; ${exposure.claimsSinceRelated} of a kind ${this.perilWord} causes.`;
        return tidyEnding(since);
    }

    // ---------- Plan and calls ----------

    get canPlan() {
        return this.hasExposure;
    }

    get planButton() {
        return this.plan ? 'Write it again' : 'Write the plan';
    }

    get planVariant() {
        return this.plan ? 'neutral' : 'brand';
    }

    get planWritten() {
        if (!this.plan?.writtenAt) {
            return '';
        }
        const at = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(new Date(this.plan.writtenAt));
        return `Written by Claude at ${at}. It is not saved: it stays while this browser tab is open.`;
    }

    /** Who to call, in Claude's order, as one sentence. */
    get planCallNames() {
        return join((this.plan?.calls ?? []).map((call) => keepTogether(call.customerName)));
    }

    listOf(lines) {
        return (lines ?? []).map((text, index) => ({ key: index, text }));
    }

    get staffing() {
        return this.listOf(this.plan?.staffing);
    }

    get coverageWatch() {
        return this.listOf(this.plan?.coverageWatch);
    }

    get notHeld() {
        return this.listOf(this.plan?.notHeld);
    }

    get hasCalls() {
        return (this.plan?.calls ?? []).length > 0;
    }

    get callRows() {
        const calls = (this.plan?.calls ?? []).map((call, index) => ({
            ...call,
            order: index + 1,
            url: `/lightning/r/Account/${call.customerId}/view`,
            who: [call.contactName, call.contactPhone].filter(Boolean).join(', ') || 'No contact on record',
            reason: tidyEnding(call.reason),
            message: this.messages[call.key] ?? '',
            isChosen: Boolean(this.chosen[call.key]),
            checkLabel: `Make a call task for ${call.customerName}`,
            messageLabel: `What to say to ${call.customerName}`
        }));
        return pageOf(calls, this.callPage, CALL_PAGE);
    }

    get callTotal() {
        return (this.plan?.calls ?? []).length;
    }

    get callPageSize() {
        return CALL_PAGE;
    }

    get chosenKeys() {
        return (this.plan?.calls ?? []).map((call) => call.key).filter((key) => this.chosen[key]);
    }

    get createLabel() {
        const chosen = this.chosenKeys.length;
        return chosen === 0 ? 'Create call tasks' : `Create ${count(chosen, 'call task', 'call tasks')}`;
    }

    get cannotCreate() {
        return this.isCreating || this.chosenKeys.length === 0 || this.chosenKeys.length > MAX_CALLS;
    }

    get createdRows() {
        return (this.created ?? []).map((task) => ({ ...task, url: `/lightning/r/Task/${task.taskId}/view` }));
    }

    get createdLine() {
        return `${count((this.created ?? []).length, 'call task is', 'call tasks are')} on your task list, due today. Nothing was sent to a customer.`;
    }

    // ---------- What people do ----------

    handleEvent(event) {
        if (event.detail.value !== this.eventName) {
            this.choose(event.detail.value);
        }
    }

    handleTab(event) {
        this.show(event.detail.value);
    }

    show(tab) {
        this.tab = tab;
        remember(`${MEMORY}tab`, tab);
    }

    /** A figure opens the list behind it. */
    handleFigure(event) {
        const key = event.currentTarget.dataset.key;
        this.lineFilter = undefined;
        this.showNearby = false;
        this.placePage = 0;
        this.show(key === 'claims' ? 'claims' : 'locations');
    }

    handleLine(event) {
        this.lineFilter = event.currentTarget.dataset.line;
        this.showNearby = false;
        this.placePage = 0;
        this.show('locations');
    }

    handleClearLine() {
        this.lineFilter = undefined;
        this.placePage = 0;
    }

    handleScope(event) {
        this.showNearby = event.detail.value === 'nearby';
        this.placePage = 0;
    }

    handlePlacePage(event) {
        this.placePage = event.detail.page;
    }

    handleClaimPage(event) {
        this.claimPage = event.detail.page;
    }

    handleCoverPage(event) {
        this.coverPage = event.detail.page;
    }

    handleCallPage(event) {
        this.callPage = event.detail.page;
    }

    handlePlace(event) {
        const key = event.currentTarget.dataset.key;
        this.selectedKey = key;
        this.template.querySelector('c-antsurance-event-map')?.showPlace(key);
    }

    handleMapPlace(event) {
        this.selectedKey = event.detail.key === this.selectedKey ? undefined : event.detail.key;
    }

    handleCloseSelected() {
        this.selectedKey = undefined;
    }

    /** With no plan yet the button says "Write the plan": it opens the Plan tab and writes it there, where the answer arrives. */
    handleWho() {
        if (this.plan) {
            this.show('calls');
            return;
        }
        this.show('plan');
        this.handlePlan();
    }

    handleSeeCalls() {
        this.show('calls');
    }

    handleSeePlan() {
        this.show('plan');
    }

    async handlePlan() {
        if (this.isPlanning) {
            return;
        }
        const name = this.eventName;
        this.isPlanning = true;
        this.planError = undefined;
        this.created = undefined;
        this.createError = undefined;
        try {
            const plan = await writePlan({ eventName: name });
            PLANS.set(name, plan);
            if (name === this.eventName) {
                this.callPage = 0;
                this.usePlan(plan);
            }
        } catch (error) {
            if (name === this.eventName) {
                this.planError = error.body?.message ?? 'The plan could not be written. Try again.';
            }
        } finally {
            this.isPlanning = false;
        }
    }

    handleChoose(event) {
        this.chosen = { ...this.chosen, [event.target.dataset.key]: event.target.checked };
    }

    handleMessage(event) {
        this.messages = { ...this.messages, [event.target.dataset.key]: event.target.value };
    }

    async handleCreate() {
        if (this.cannotCreate) {
            return;
        }
        this.isCreating = true;
        this.createError = undefined;
        try {
            this.created = await createCallTasks({
                eventName: this.eventName,
                calls: this.chosenKeys.map((key) => ({ key, message: this.messages[key] ?? '' }))
            });
            this.chosen = {};
        } catch (error) {
            this.createError = error.body?.message ?? 'The call tasks could not be created. Try again.';
        } finally {
            this.isCreating = false;
        }
    }

    /** Opens a record. A modified click is left to the browser, for a new tab. */
    handleOpen(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }
}
