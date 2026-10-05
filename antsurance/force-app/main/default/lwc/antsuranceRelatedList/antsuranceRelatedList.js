import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord } from 'lightning/uiRecordApi';
import { getRelatedListRecords, getRelatedListCount } from 'lightning/uiRelatedListApi';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { refreshApex } from '@salesforce/apex';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { iconFor } from 'c/antsuranceIcons';
import { pageOf } from 'c/antsuranceUiMemory';

// The most rows asked for at first. Stepping past them asks for more, a batch at a time, up to the most
// held for paging through in place. A list longer than that ends at "View all".
const MOST_LOADED = 48;
const MOST_HELD = 240;

// After New opens there is no signal when it is saved, so the list looks again a few times.
const RECHECKS_AFTER_NEW = 10;
const RECHECK_EVERY_MS = 4000;

// What a status word means for its chip. Anything not named here is drawn as a plain chip.
const GOOD = ['active', 'approved', 'bound', 'closed won', 'issued', 'paid', 'payment issued', 'in force', 'accepted', 'presented'];
const WATCH = ['pending renewal', 'new', 'under investigation', 'appraisal', 'in progress', 'waiting on customer', 'draft', 'needs review', 'underwriting review', 'quote issued', 'bind requested', 'submission received', 'pending'];
const ENDED = ['closed', 'cancelled', 'canceled', 'lapsed', 'expired', 'denied', 'declined', 'removed', 'inactive'];

const DATE_FORMAT = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
const WHOLE = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/**
 * One related list on a record page, drawn at once in the house style: a title with its count,
 * the columns the page asks for, rows that link to their records, and "View all" to the full list.
 * It reads through Lightning Data Service, so the user's field access applies.
 *
 * `fields` is a comma-separated list of columns, each "FieldPath|Header|kind". The kind is one of
 * link (the row's own record), lookup (a parent's name, linked to the parent), money, date, chip,
 * number, percent or text (the default). The first columns matter most: later ones drop out when
 * the list is drawn narrow.
 *
 * `icon` puts a small icon ahead of each row's name, from the shared mapping in c/antsuranceIcons.
 * It is "kind:FieldPath" when the icon depends on the row ("asset:Asset_Type__c", "role:Role__c",
 * "line:Line_of_Business__c", "coverage:Name", "kind:Kind__c") or a kind alone when every row is the
 * same sort of thing ("person", "sale", "quote").
 *
 * `through` shows a list that belongs to the record this one sits under: on an insured asset's page, set
 * to "Policy__c", the list is the policy's claims. The page's own record is only where the list starts from,
 * and when the list is of its own kind (the policy's other assets) it is left out, since the page is about it.
 */
export default class AntsuranceRelatedList extends NavigationMixin(LightningElement) {
    @api
    get recordId() {
        return this.pageRecordId;
    }
    set recordId(value) {
        this.pageRecordId = value;
        this.resolve();
    }
    pageRecordId;
    @api
    get objectApiName() {
        return this.pageObject;
    }
    set objectApiName(value) {
        this.pageObject = value;
        this.resolve();
    }
    pageObject;
    /** The page record's lookup to the record whose list this is ("Policy__c"), when the list is not the page record's own. */
    @api
    get through() {
        return this.lookupName;
    }
    set through(value) {
        this.lookupName = value;
        this.resolve();
    }
    lookupName;
    // The record whose list is shown and its object, and what the lookup wire is asked for.
    ownerId;
    ownerObject;
    lookupFields;
    /** The child relationship, as the related list is named: "Contacts", "Coverages__r". */
    @api relatedListId;
    /** The child object's API name, which qualifies the field names. */
    @api
    get childObject() {
        return this.child;
    }
    set childObject(value) {
        this.child = value;
        this.configure();
    }
    child;
    /** The lookup on the child that points back at this record; when set, the list offers New. */
    @api parentField;
    @api title;
    @api
    get fields() {
        return this.fieldList;
    }
    set fields(value) {
        this.fieldList = value;
        this.configure();
    }
    fieldList;
    /** One line under the title saying how to read the list ("Already in the annual premium."). */
    @api note;
    /** The fields to sort by, in order, comma-separated, each with a leading "-" for newest or largest first. */
    @api
    get sortBy() {
        return this.sortField;
    }
    set sortBy(value) {
        this.sortField = value;
        this.configure();
    }
    sortField;
    /** Which icon leads each row: "kind:FieldPath" or a kind alone. */
    @api
    get icon() {
        return this.iconSpec;
    }
    set icon(value) {
        this.iconSpec = value;
        this.configure();
    }
    iconSpec;
    iconKind;
    iconPath;
    @api rows = 6;
    @api emptyText = 'Nothing here yet.';
    /**
     * "GroupPath|JoinPath". Rows that share the record at the end of GroupPath become one row, with the values of
     * JoinPath joined: a person who is the named insured and a driver on one policy reads "Named Insured, Driver".
     */
    @api mergeBy;

    // What the wire adapters are asked for. These are set once per change of the properties above,
    // because a new array on every read would make the adapters ask again on every render.
    columns = [];
    wireFields;
    wireSort;
    records;
    recordsResult;
    total;
    countResult;
    errorMessage;
    recheckTimer;
    // The page of rows in view, from 0.
    page = 0;
    // How many rows the pager has asked to have loaded, once it steps past the first batch, and the page it is waiting to turn to.
    wanted = 0;
    pendingPage;
    rechecksLeft = 0;

    connectedCallback() {
        loadBrandFonts(this);
    }

    disconnectedCallback() {
        this.stopRechecking();
    }

    /** Works out whose list to show: the page's own record, or the one its lookup points at. */
    resolve() {
        if (!this.lookupName) {
            this.lookupFields = undefined;
            this.ownerId = this.pageRecordId;
            this.ownerObject = this.pageObject;
        } else if (this.pageObject) {
            // The relationship is asked for, not the bare lookup, because it also says what kind of record the owner is.
            this.lookupFields = [`${this.pageObject}.${this.relationshipName}.Id`];
        }
    }

    /** True for a list one step up whose rows are the same kind of record as the page's own: the page's record is not listed. */
    get leavesItselfOut() {
        return Boolean(this.lookupName) && this.child === this.pageObject;
    }

    /** The lookup as a relationship: "Policy__c" is reached through "Policy__r", "AccountId" through "Account". */
    get relationshipName() {
        return this.lookupName.endsWith('__c') ? this.lookupName.replace(/__c$/, '__r') : this.lookupName.replace(/Id$/, '');
    }

    @wire(getRecord, { recordId: '$pageRecordId', fields: '$lookupFields' })
    wiredOwner({ data }) {
        if (data && this.lookupName) {
            const owner = data.fields[this.relationshipName]?.value;
            this.ownerId = owner?.id;
            this.ownerObject = owner?.apiName;
            if (!owner) {
                // The lookup is empty, so there is no list to read: the card shows its empty line.
                this.records = [];
            }
        }
    }

    configure() {
        this.columns = (this.fieldList ?? '')
            .split(',')
            .map((entry) => entry.trim())
            .filter(Boolean)
            .map((entry, index) => {
                const [path, label, kind = 'text'] = entry.split('|').map((part) => part.trim());
                const isAmount = ['money', 'number', 'percent'].includes(kind);
                return {
                    path,
                    label,
                    kind,
                    index,
                    // Columns past the third give way first when the card is narrow.
                    className: `c-list__cell c-list__cell_${kind}${isAmount ? ' c-list__cell_amount' : ''}${index >= 3 ? ' c-list__cell_extra' : ''}${index === 2 ? ' c-list__cell_third' : ''}`
                };
            });
        const [iconKind, iconPath] = (this.iconSpec ?? '').split(':').map((part) => part.trim());
        this.iconKind = iconKind || undefined;
        this.iconPath = iconPath || undefined;
        // The icon's field is read with the columns even when it is not one of them.
        const paths = this.columns.map((column) => column.path);
        if (this.iconPath && !paths.includes(this.iconPath)) {
            paths.push(this.iconPath);
        }
        this.wireFields = this.child && this.columns.length ? paths.map((path) => `${this.child}.${path}`) : undefined;
        if (this.sortField && this.child) {
            this.wireSort = String(this.sortField)
                .split(',')
                .map((field) => field.trim())
                .filter(Boolean)
                .map((field) => {
                    const descending = field.startsWith('-');
                    return `${descending ? '-' : ''}${this.child}.${descending ? field.slice(1) : field}`;
                });
        } else {
            this.wireSort = undefined;
        }
    }

    /** How many rows are in view at once. */
    get pageSize() {
        return Number(this.rows) || 6;
    }

    /** Several pages are loaded in the one request, so stepping through them asks the server nothing more. */
    get loadSize() {
        return Math.max(this.firstLoad, Math.min(MOST_HELD, this.wanted));
    }

    get firstLoad() {
        return Math.min(MOST_LOADED, this.pageSize * 8);
    }

    /**
     * What the pager counts to: the whole list, when its count is known, so "1 to 10 of 52" agrees with
     * the 52 beside the title and on "View all". Merged rows and a count too large to know keep to what is loaded.
     */
    get pagerTotal() {
        return !this.mergeBy && typeof this.total === 'number' ? Math.max(this.total, this.loadedCount) : this.loadedCount;
    }

    get loadedCount() {
        return this.listed?.length ?? 0;
    }

    /** The rows to list: the records as loaded, or the first of each group when mergeBy is set. */
    get listed() {
        return this.merge().rows;
    }

    /** Groups the loaded records by mergeBy. `joined` holds each kept row's joined text, by record id. */
    merge() {
        if (!this.records || !this.mergeBy) {
            return { rows: this.records, joined: new Map(), path: undefined };
        }
        const [groupPath, joinPath] = String(this.mergeBy)
            .split('|')
            .map((part) => part.trim());
        const groups = new Map();
        this.records.forEach((record) => {
            const { field, owner } = this.read(record, groupPath);
            const key = owner && owner !== record && owner.id ? owner.id : (field?.value ?? record.id);
            const joinField = this.read(record, joinPath).field;
            const text = joinField?.displayValue ?? joinField?.value;
            if (!groups.has(key)) {
                groups.set(key, { record, texts: [] });
            }
            if (text && !groups.get(key).texts.includes(text)) {
                groups.get(key).texts.push(text);
            }
        });
        const kept = [...groups.values()];
        return { rows: kept.map((group) => group.record), joined: new Map(kept.map((group) => [group.record.id, group.texts.join(', ')])), path: joinPath };
    }

    get pagerLabel() {
        return (this.title ?? 'rows').toLowerCase();
    }

    handlePage(event) {
        const page = event.detail.page;
        const needed = Math.min((page + 1) * this.pageSize, this.pagerTotal);
        if (needed > this.loadedCount) {
            // Past the rows held here: ask for the next batch and turn the page when it arrives, or, past
            // the most this card holds, open the full list.
            const wanted = Math.min(MOST_HELD, Math.ceil(needed / this.firstLoad) * this.firstLoad);
            if (wanted > this.loadSize) {
                this.pendingPage = page;
                this.wanted = wanted;
                return;
            }
            if (page * this.pageSize >= this.loadedCount) {
                this.handleViewAll(event);
                return;
            }
        }
        this.page = page;
    }

    @wire(getRelatedListRecords, { parentRecordId: '$ownerId', relatedListId: '$relatedListId', fields: '$wireFields', sortBy: '$wireSort', pageSize: '$loadSize' })
    wiredRecords(result) {
        this.recordsResult = result;
        if (result.data) {
            this.records = this.leavesItselfOut ? result.data.records.filter((record) => record.id !== this.pageRecordId) : result.data.records;
            this.errorMessage = undefined;
            if (this.pendingPage !== undefined) {
                this.page = this.pendingPage;
                this.pendingPage = undefined;
            }
        } else if (result.error) {
            const body = result.error.body;
            this.errorMessage = (Array.isArray(body) ? body[0]?.message : body?.message) ?? 'This list could not be loaded.';
        }
    }

    // Without a ceiling the count stops at a small default and reads "20+".
    @wire(getRelatedListCount, { parentRecordId: '$ownerId', relatedListId: '$relatedListId', maxCount: 500 })
    wiredCount(result) {
        this.countResult = result;
        if (result.data) {
            const count = this.leavesItselfOut ? Math.max(result.data.count - 1, 0) : result.data.count;
            this.total = result.data.hasMore ? `${count}+` : count;
        }
    }

    get isLoading() {
        return !this.records && !this.errorMessage;
    }

    get hasRows() {
        return this.records?.length > 0;
    }

    get isEmpty() {
        return Boolean(this.records) && this.records.length === 0;
    }

    /** The count beside the title: the full number when known, otherwise what is on screen. */
    get countLabel() {
        if (this.mergeBy && this.records) {
            // The server counts rows; merged, the list holds fewer.
            return String(this.listed.length);
        }
        if (this.total !== undefined) {
            return String(this.total);
        }
        return this.records ? String(this.records.length) : '';
    }

    get showViewAll() {
        return this.hasRows;
    }

    get viewAllLabel() {
        // The number is worth saying when there is more than one page in view shows.
        return typeof this.total === 'number' && this.total > this.pageSize ? `View all ${this.total}` : 'View all';
    }

    get viewAllUrl() {
        return `/lightning/r/${this.ownerObject}/${this.ownerId}/related/${this.relatedListId}/view`;
    }

    get canCreate() {
        return Boolean(this.parentField && this.child);
    }

    get ariaLabel() {
        return this.title;
    }

    /** Follows "Account__r.Name" through a record to the field at the end, and the parent it sits on. */
    read(record, path) {
        const parts = path.split('.');
        let node = record;
        for (let i = 0; i < parts.length - 1; i += 1) {
            node = node?.fields?.[parts[i]]?.value;
        }
        return { field: node?.fields?.[parts[parts.length - 1]], owner: node };
    }

    format(kind, field) {
        const value = field?.value;
        if (value === null || value === undefined || value === '') {
            return '';
        }
        switch (kind) {
            case 'money': {
                // A credit reads "-$190", with the sign ahead of the dollar sign.
                const amount = Math.round(Number(value));
                // An amount of nothing is left blank. "$0" under "Still to pay" on a service request, which has
                // no money on it at all, read as a figure someone had set.
                if (amount === 0) {
                    return '';
                }
                return `${amount < 0 ? '-' : ''}$${WHOLE.format(Math.abs(amount))}`;
            }
            case 'number':
                return WHOLE.format(Number(value));
            case 'percent':
                return `${WHOLE.format(Number(value))}%`;
            case 'date': {
                const [year, month, day] = String(value).slice(0, 10).split('-').map(Number);
                return DATE_FORMAT.format(new Date(year, month - 1, day));
            }
            default:
                return field.displayValue ?? String(value);
        }
    }

    chipClass(text) {
        const word = text.toLowerCase();
        if (GOOD.includes(word)) {
            return 'c-chip c-chip_good';
        }
        if (WATCH.includes(word)) {
            return 'c-chip c-chip_watch';
        }
        return ENDED.includes(word) ? 'c-chip c-chip_ended' : 'c-chip';
    }

    get hasIcons() {
        return Boolean(this.iconKind);
    }

    /** Three rows the shape of what is coming, so the card does not jump when the records arrive. */
    get skeletonRows() {
        return [1, 2, 3].map((key) => ({ key, lineClass: `c-ui-bone c-ui-bone_line c-skeleton__line c-skeleton__line_${key}` }));
    }

    iconOf(record) {
        if (!this.iconKind) {
            return undefined;
        }
        const value = this.iconPath ? this.read(record, this.iconPath).field?.value : undefined;
        const found = this.iconPath ? iconFor(this.iconKind, value) : iconFor('kind', this.iconKind);
        return { name: found.name, tileClass: `${found.tileClass} c-ui-tile_small c-list__icon`, label: value ?? this.iconKind };
    }

    get tableRows() {
        const columns = this.columns;
        const merged = this.merge();
        return pageOf(merged.rows, this.page, this.pageSize).map((record) => {
            const cells = this.cellsOf(record, columns);
            const joined = merged.joined.get(record.id);
            cells.filter((cell) => cell.path === merged.path && joined).forEach((cell) => {
                cell.text = joined;
            });
            // The row opens what its name opens: its own record, or the parent its first link points at.
            const opens = cells.find((cell) => cell.isLinked);
            if (cells.length) {
                cells[0].icon = this.iconOf(record);
            }
            return { id: record.id, cells, targetId: opens?.targetId, className: opens ? 'c-list__row c-ui-open' : 'c-list__row' };
        });
    }

    cellsOf(record, columns) {
        return columns.map((column) => {
                const { field, owner } = this.read(record, column.path);
                const text = this.format(column.kind, field);
                const isLink = column.kind === 'link' && Boolean(text);
                const isLookup = column.kind === 'lookup' && Boolean(text) && Boolean(owner?.id);
                const targetId = isLink ? record.id : isLookup ? owner.id : undefined;
                return {
                    key: `${record.id}-${column.index}`,
                    path: column.path,
                    className: column.className,
                    label: column.label,
                    text,
                    isLinked: isLink || isLookup,
                    // The first column names the row, so it reads as the main link whether it is the row's own record or its parent.
                    linkClass: isLink || column.index === 0 ? 'c-list__link c-list__link_main' : 'c-list__link',
                    targetId,
                    url: targetId ? `/lightning/r/${targetId}/view` : undefined,
                    isChip: column.kind === 'chip' && Boolean(text),
                    chipClass: column.kind === 'chip' && text ? this.chipClass(text) : undefined,
                    isPlain: !isLink && !isLookup && column.kind !== 'chip'
                };
        });
    }

    /** A click anywhere on a row opens it; a click on a link inside is left to the link. */
    handleRowClick(event) {
        const recordId = event.currentTarget.dataset.recordId;
        if (!recordId || event.target.closest('a') || event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
    }

    handleOpen(event) {
        // The link keeps its address for "open in a new tab"; a plain click stays inside the app.
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }

    handleViewAll(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: { recordId: this.ownerId, objectApiName: this.ownerObject, relationshipApiName: this.relatedListId, actionName: 'view' }
        });
    }

    handleNew() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: this.child, actionName: 'new' },
            state: { defaultFieldValues: encodeDefaultFieldValues({ [this.parentField]: this.ownerId }), navigationLocation: 'RELATED_LIST' }
        });
        this.stopRechecking();
        this.rechecksLeft = RECHECKS_AFTER_NEW;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.recheckTimer = setInterval(() => {
            this.rechecksLeft -= 1;
            this.refresh();
            if (this.rechecksLeft <= 0) {
                this.stopRechecking();
            }
        }, RECHECK_EVERY_MS);
    }

    /** Asks for the list again. Pages call this after an action that adds or changes rows. */
    @api
    async refresh() {
        try {
            await Promise.all([this.recordsResult ? refreshApex(this.recordsResult) : undefined, this.countResult ? refreshApex(this.countResult) : undefined]);
        } catch (error) {
            // The rows on screen stay as they are; the next visit to the page reads them fresh.
        }
    }

    stopRechecking() {
        if (this.recheckTimer) {
            clearInterval(this.recheckTimer);
            this.recheckTimer = undefined;
        }
    }
}
