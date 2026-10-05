import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import completeTask from '@salesforce/apex/AntsuranceWorkController.completeTask';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';
import { pageOf } from 'c/antsuranceUiMemory';
import { compactMoney, count, daysBetween, fullDate, money, plural, shortDate, toDate } from 'c/antsuranceCockpitFormat';

const TASKS_TAB = 'Antsurance_Tasks';
// A renewal this close is urgent; this close, worth a look. A quote that has waited this long is overdue for a chase.
const URGENT_RENEWAL_DAYS = 14;
const SOON_RENEWAL_DAYS = 30;
const OVERDUE_QUOTE_DAYS = 30;
const SERIOUS = ['Catastrophic', 'High'];
// How many rows of a list are in view at once. The rest are a step away, so no tab runs past about one screen.
const ROWS_SHOWN = 6;

const OBJECT_OF_KIND = { Claim: 'Case', 'Service request': 'Case', 'Policy sale': 'Opportunity', Quote: 'Quote', Policy: 'Policy__c', Customer: 'Account' };

const list = (objectApiName, filterName) => ({ type: 'standard__objectPage', attributes: { objectApiName, actionName: 'list' }, state: { filterName } });

/**
 * The lower half of Home: six tabs, one list open at a time, six rows of it in view with the
 * rest a step away. A row shows the one line that identifies it and its chips; pressing it opens
 * the detail and the actions in place, so the person can decide what to do without leaving Home.
 */
export default class AntsuranceCockpitWorkspace extends NavigationMixin(LightningElement) {
    @api cockpit;
    /** The tab the person picked. Until they pick one, the desk shows when work waits on it, and My day otherwise. */
    pickedTab;
    /** The open row, as "tab:recordId". One row is open at a time. */
    openRow;
    /** The stage picked on the pipeline bar. Until one is picked, the first stage that has sales. */
    pickedStage;
    isCompleting = false;
    errorMessage;
    /** The page each list is on, by list name. */
    pages = {};
    /** The group of tasks picked on My day, and the list picked on Pipeline. Until one is picked, the first that has rows. */
    pickedDayGroup;
    pickedPipeView;

    connectedCallback() {
        loadBrandFonts(this);
    }

    get isReady() {
        return Boolean(this.cockpit);
    }

    get activeTab() {
        return this.pickedTab ?? (this.cockpit?.desk?.waiting > 0 ? 'desk' : 'day');
    }

    set activeTab(value) {
        this.pickedTab = value;
    }

    /** Shows one of the tabs. Home calls this when the briefing sends the person to Claude's desk. */
    @api
    showTab(key) {
        this.pickedTab = key;
        this.errorMessage = undefined;
    }

    /** Puts the keyboard on the tab in view, without moving the page. For Home, after it has brought the workspace up. */
    @api
    focusTab() {
        this.template.querySelector('.c-tab_selected')?.focus({ preventScroll: true });
    }

    /** Reloads Claude's desk after something elsewhere on Home changed a record. */
    @api
    refreshDesk() {
        this.refs.desk?.refresh();
    }

    // ------------------------------------------------------------------ tabs

    get tabs() {
        const cockpit = this.cockpit;
        const counts = cockpit
            ? {
                  desk: cockpit.desk?.waiting ?? 0,
                  // What the tab lists: overdue, due today and the next few by due date.
                  day: cockpit.tasks.length,
                  claims: cockpit.figures.openClaimCount,
                  renewals: cockpit.renewalCount,
                  pipeline: cockpit.openSaleCount,
                  underwriting: cockpit.referrals.length
              }
            : {};
        return [
            { key: 'desk', label: "Claude's desk" },
            { key: 'day', label: 'My day' },
            { key: 'claims', label: 'Claims' },
            { key: 'renewals', label: 'Renewals' },
            { key: 'pipeline', label: 'Pipeline' },
            { key: 'underwriting', label: 'Underwriting' }
        ].map((tab) => {
            const selected = tab.key === this.activeTab;
            return {
                ...tab,
                count: cockpit ? count(counts[tab.key]) : '',
                hasCount: Boolean(cockpit),
                selected: selected ? 'true' : 'false',
                tabIndex: selected ? 0 : -1,
                className: selected ? 'c-tab c-tab_selected' : 'c-tab'
            };
        });
    }

    get showDesk() {
        return this.activeTab === 'desk';
    }

    /** The desk stays alive while another tab shows, so a shift in progress carries on. */
    get deskPanelClass() {
        return this.showDesk ? 'c-panel' : 'c-panel c-panel_away';
    }

    /** The desk has changed a record or its own queue: Home reloads its counts and lists. */
    handleDeskChanged() {
        this.dispatchEvent(new CustomEvent('changed', { detail: { from: 'desk' } }));
    }

    get showDay() {
        return this.activeTab === 'day';
    }

    get showClaims() {
        return this.activeTab === 'claims';
    }

    get showRenewals() {
        return this.activeTab === 'renewals';
    }

    get showPipeline() {
        return this.activeTab === 'pipeline';
    }

    get showUnderwriting() {
        return this.activeTab === 'underwriting';
    }

    handleTab(event) {
        this.holdHeight();
        this.activeTab = event.currentTarget.dataset.key;
        this.errorMessage = undefined;
    }

    /**
     * Each list has its own height. Without a floor the card shrinks when a shorter list is chosen, the
     * page gets shorter and everything jumps under the pointer. So the card never gets shorter than the
     * tallest list seen so far, up to about a screen.
     */
    holdHeight() {
        const card = this.template.querySelector('.c-work');
        if (!card) {
            return;
        }
        const limit = Math.max(320, window.innerHeight - 220);
        const held = Math.min(limit, Math.max(this.heldHeight ?? 0, card.getBoundingClientRect().height));
        this.heldHeight = held;
        // The room is held under the card, not inside it: the card ends where its list ends, so a short
        // list is not followed by a third of a card left blank, and the page is still no shorter.
        this.template.host.style.minHeight = `${Math.round(held)}px`;
    }

    /** Left and right arrows move between tabs, as a tab list should. */
    handleTabKey(event) {
        if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') {
            return;
        }
        this.holdHeight();
        const keys = this.tabs.map((tab) => tab.key);
        const step = event.key === 'ArrowRight' ? 1 : -1;
        this.activeTab = keys[(keys.indexOf(this.activeTab) + step + keys.length) % keys.length];
        event.preventDefault();
        // Focus follows the selection once the tab strip has redrawn.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => this.template.querySelector('.c-tab_selected')?.focus());
    }

    // ------------------------------------------------------------------ rows

    /** What every row needs to open and close. */
    row(tab, recordId) {
        const key = `${tab}:${recordId}`;
        const isOpen = this.openRow === key;
        return { key, isOpen, expanded: isOpen ? 'true' : 'false', className: isOpen ? 'c-row c-row_open' : 'c-row' };
    }

    handleToggle(event) {
        const { key } = event.currentTarget.dataset;
        this.openRow = this.openRow === key ? undefined : key;
    }

    // ------------------------------------------------------------------ a page of a list

    get rowsShown() {
        return ROWS_SHOWN;
    }

    paged(name, rows) {
        return pageOf(rows, this.pages[name] ?? 0, ROWS_SHOWN);
    }

    handlePage(event) {
        this.pages = { ...this.pages, [event.currentTarget.dataset.list]: event.detail.page };
        // The open row belongs to the page that was left.
        this.openRow = undefined;
    }

    // ------------------------------------------------------------------ my day

    get daySummary() {
        const { overdueTaskCount, todayTaskCount, openTaskCount } = this.cockpit;
        if (overdueTaskCount + todayTaskCount === 0) {
            return `Nothing overdue or due today. ${plural(openTaskCount, 'task')} open in all.`;
        }
        return `${count(overdueTaskCount)} overdue and ${count(todayTaskCount)} due today, of ${plural(openTaskCount, 'open task')}.`;
    }

    get taskGroups() {
        const weekday = new Intl.DateTimeFormat(LOCALE, { weekday: 'short', month: 'short', day: 'numeric' });
        const groups = [
            { key: 'overdue', label: 'Overdue', labelClass: 'c-group__label c-group__label_alert', rows: [] },
            { key: 'today', label: 'Today', labelClass: 'c-group__label', rows: [] },
            { key: 'next', label: 'Next', labelClass: 'c-group__label', rows: [] }
        ];
        this.cockpit.tasks.forEach((task) => {
            const days = daysBetween(this.cockpit.today, task.dueDate);
            let group = groups[2];
            let dueLabel = days === 1 ? 'Tomorrow' : weekday.format(toDate(task.dueDate));
            let dueClass = 'c-chip';
            if (days < 0) {
                group = groups[0];
                dueLabel = `${-days} ${days === -1 ? 'day' : 'days'} overdue`;
                dueClass = 'c-chip c-chip_alert';
            } else if (days === 0) {
                group = groups[1];
                dueLabel = 'Today';
                dueClass = 'c-chip c-chip_good';
            }
            group.rows.push({
                ...task,
                ...this.row('day', task.recordId),
                about: keepTogether(task.relatedName),
                hasAbout: Boolean(task.relatedName),
                kind: task.relatedKind,
                aboutObject: OBJECT_OF_KIND[task.relatedKind],
                aboutLabel: task.relatedKind ? `Open ${task.relatedKind.toLowerCase()}` : 'Open record',
                canOpenAbout: Boolean(task.relatedId && OBJECT_OF_KIND[task.relatedKind]),
                dueLabel,
                dueClass,
                dueDateLabel: fullDate(task.dueDate),
                isHigh: task.priority === 'High',
                priorityLabel: task.priority ?? 'Normal',
                completeLabel: `Mark complete: ${task.subject}`
            });
        });
        return groups.filter((group) => group.rows.length > 0).map((group) => ({ ...group, count: count(group.rows.length) }));
    }

    get hasTasks() {
        return this.cockpit.tasks.length > 0;
    }

    /** Overdue, today and the next few as a small row of tabs, so one group is in view at a time. */
    get dayTabs() {
        return this.taskGroups.map((group) => ({ value: group.key, label: group.label, count: group.rows.length, tone: group.key === 'overdue' ? 'watch' : undefined }));
    }

    get hasSeveralDayGroups() {
        return this.dayTabs.length > 1;
    }

    get dayGroup() {
        const groups = this.taskGroups;
        return groups.find((group) => group.key === this.pickedDayGroup) ?? groups[0];
    }

    get dayGroupKey() {
        return this.dayGroup?.key;
    }

    get dayPageName() {
        return `day-${this.dayGroupKey}`;
    }

    get dayPage() {
        return this.pages[this.dayPageName] ?? 0;
    }

    get shownTasks() {
        return this.paged(this.dayPageName, this.dayGroup?.rows ?? []);
    }

    get dayTotal() {
        return this.dayGroup?.rows.length ?? 0;
    }

    get dayPagerLabel() {
        return `${(this.dayGroup?.label ?? '').toLowerCase()} tasks`;
    }

    handleDayGroup(event) {
        this.pickedDayGroup = event.detail.value;
        this.openRow = undefined;
    }

    async handleComplete(event) {
        this.isCompleting = true;
        this.errorMessage = undefined;
        try {
            await completeTask({ taskId: event.currentTarget.dataset.recordId });
            this.openRow = undefined;
            // Home reloads its lists, and the briefing ticks the task off if it named it.
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'That task could not be completed.';
        } finally {
            this.isCompleting = false;
        }
    }

    // ------------------------------------------------------------------ claims

    get claimSummary() {
        const { figures, claims } = this.cockpit;
        if (figures.openClaimCount === 0) {
            return 'No open claims.';
        }
        const shown = claims.length < figures.openClaimCount ? ` These ${count(claims.length)} are the most serious that have waited longest.` : '';
        return `${plural(figures.openClaimCount, 'open claim')} with ${compactMoney(figures.outstandingReserve)} still reserved.${shown}`;
    }

    get claims() {
        return this.cockpit.claims.map((claim) => {
            const reserve = claim.reserve ?? 0;
            const paid = claim.paid ?? 0;
            const paidShare = reserve > 0 ? Math.min(100, Math.round((paid / reserve) * 100)) : 0;
            // The shared severity chip, in the same words and fill as on the claim itself.
            const severityClass = SERIOUS.includes(claim.severity) ? 'c-ui-severity c-ui-severity_serious' : 'c-ui-severity';
            const daysOpen = claim.reportedDate ? daysBetween(claim.reportedDate, this.cockpit.today) : undefined;
            // The list is ordered by how long each claim has waited, so each row says how long that is.
            const waited = daysOpen === undefined ? undefined : `open ${plural(daysOpen, 'day')}`;
            return {
                ...claim,
                ...this.row('claims', claim.recordId),
                subject: keepTogether(claim.subject),
                severityLabel: claim.severity ? `Severity: ${claim.severity}` : 'Severity not set',
                subLabel: [claim.accountName, waited].filter(Boolean).join(', '),
                severityClass,
                outstandingLabel: money(claim.outstanding),
                reserveLabel: money(reserve),
                paidLabel: money(paid),
                paidStyle: `width: ${paidShare}%`,
                paidShare: `${paidShare}% of the reserve has been paid`,
                daysOpenLabel: daysOpen === undefined ? 'Not recorded' : plural(daysOpen, 'day'),
                reportedLabel: fullDate(claim.reportedDate),
                handledByLabel: claim.handledBy ?? 'Not assigned',
                hasBrief: Boolean(claim.briefHeadline),
                briefHeadline: keepTogether(claim.briefHeadline)
            };
        });
    }

    get shownClaims() {
        return this.paged('claims', this.claims);
    }

    get hasClaims() {
        return this.cockpit.claims.length > 0;
    }

    // ------------------------------------------------------------------ renewals

    get renewalSummary() {
        const { renewalCount, renewalPremium } = this.cockpit;
        if (renewalCount === 0) {
            return 'No policies renew in the next 60 days.';
        }
        return `${plural(renewalCount, 'policy renews', 'policies renew')} in the next 60 days, ${compactMoney(renewalPremium)} of premium. Soonest first.`;
    }

    get renewals() {
        return this.cockpit.renewals.map((renewal) => {
            const daysLeft = daysBetween(this.cockpit.today, renewal.expirationDate);
            let countdownClass = 'c-countdown';
            if (daysLeft <= URGENT_RENEWAL_DAYS) {
                countdownClass += ' c-countdown_urgent';
            } else if (daysLeft <= SOON_RENEWAL_DAYS) {
                countdownClass += ' c-countdown_soon';
            }
            const isPriced = renewal.renewalPremium != null && renewal.premium != null;
            const change = isPriced ? renewal.renewalPremium - renewal.premium : 0;
            let changeLabel = 'Not priced yet';
            let changeClass = 'c-fact__value';
            if (isPriced) {
                const share = renewal.premium > 0 ? ` (${Math.abs((change / renewal.premium) * 100).toFixed(1)}%)` : '';
                if (change > 0) {
                    changeLabel = `Up ${money(change)}${share}`;
                    changeClass += ' c-fact__value_alert';
                } else if (change < 0) {
                    changeLabel = `Down ${money(-change)}${share}`;
                    changeClass += ' c-fact__value_good';
                } else {
                    changeLabel = 'No change';
                }
            }
            const isPending = renewal.status === 'Pending Renewal';
            return {
                ...renewal,
                ...this.row('renewals', renewal.recordId),
                daysLeft: count(daysLeft),
                daysUnit: daysLeft === 1 ? 'day' : 'days',
                countdownClass,
                detail: keepTogether(`${renewal.lineOfBusiness}, ${renewal.policyNumber}`),
                premiumLabel: money(renewal.premium),
                renewalPremiumLabel: isPriced ? money(renewal.renewalPremium) : 'Not priced yet',
                changeLabel,
                changeClass,
                expiresLabel: fullDate(renewal.expirationDate),
                // The policy's own status word, the same one its page shows. Nothing here knows whether the offer has been sent.
                statusLabel: isPending ? renewal.status : 'Renewal not started',
                statusClass: isPending ? 'c-chip c-chip_watch' : 'c-chip',
                paymentLabel: renewal.paymentStatus ?? 'Not recorded',
                stageLabel: renewal.renewalStage ?? 'No renewal sale yet',
                hasSale: Boolean(renewal.renewalSaleId)
            };
        });
    }

    get shownRenewals() {
        return this.paged('renewals', this.renewals);
    }

    get hasRenewals() {
        return this.cockpit.renewals.length > 0;
    }

    // ------------------------------------------------------------------ pipeline

    get pipelineSummary() {
        const { openSaleCount, openSaleAmount } = this.cockpit;
        if (openSaleCount === 0) {
            return 'No open policy sales.';
        }
        return `${plural(openSaleCount, 'open policy sale')} worth ${compactMoney(openSaleAmount)} in premium. Pick a stage to see its largest sales.`;
    }

    get activeStage() {
        const stages = this.cockpit.stages;
        return stages.find((stage) => stage.name === this.pickedStage) ?? stages.find((stage) => stage.saleCount > 0) ?? stages[0];
    }

    get stages() {
        const active = this.activeStage;
        return this.cockpit.stages.map((stage, index) => {
            const selected = stage === active;
            return {
                ...stage,
                key: stage.name,
                step: index + 1,
                countLabel: plural(stage.saleCount, 'sale'),
                // To the nearest thousand from $10K up, so the four tiles read alike: $42K beside $103K, not $41.9K.
                amountLabel: compactMoney(Math.abs(stage.amount ?? 0) >= 10000 ? Math.round(stage.amount / 1000) * 1000 : stage.amount),
                pressed: selected ? 'true' : 'false',
                className: selected ? 'c-stage c-stage_selected' : 'c-stage'
            };
        });
    }

    get stageHeading() {
        const stage = this.activeStage;
        if (!stage || stage.saleCount === 0) {
            return stage ? `No sales at ${stage.name}` : '';
        }
        return stage.sales.length < stage.saleCount ? `The ${count(stage.sales.length)} largest of ${count(stage.saleCount)} at ${stage.name}` : `At ${stage.name}`;
    }

    get stageSales() {
        return (this.activeStage?.sales ?? []).map((sale) => ({
            ...sale,
            ...this.row('stage', sale.recordId),
            name: keepTogether(sale.name),
            amountLabel: money(sale.amount),
            closeLabel: sale.closeDate ? `Closes ${shortDate(sale.closeDate)}` : 'No close date',
            customerLabel: sale.customerName ?? 'Not recorded',
            lineLabel: sale.lineOfBusiness ?? 'Not recorded',
            nextLabel: sale.nextStep ? keepTogether(sale.nextStep) : 'Not recorded'
        }));
    }

    get hasStageSales() {
        return this.stageSales.length > 0;
    }

    handleStage(event) {
        this.pickedStage = event.currentTarget.dataset.key;
        this.pages = { ...this.pages, stage: 0 };
    }

    get shownStageSales() {
        return this.paged('stage', this.stageSales);
    }

    /** Pipeline holds two lists: the sales at the picked stage, and the quotes that have waited too long. One shows at a time. */
    get pipeTabs() {
        return [
            { value: 'stage', label: 'Sales by stage', count: this.cockpit.openSaleCount },
            { value: 'waiting', label: 'Quotes waiting', count: this.cockpit.staleQuotes.length, tone: this.cockpit.staleQuotes.length ? 'watch' : undefined }
        ];
    }

    get pipeView() {
        return this.pickedPipeView ?? 'stage';
    }

    get showsStage() {
        return this.pipeView === 'stage';
    }

    get showsWaiting() {
        return this.pipeView === 'waiting';
    }

    handlePipeView(event) {
        this.pickedPipeView = event.detail.value;
        this.openRow = undefined;
    }

    get shownStaleQuotes() {
        return this.paged('waiting', this.staleQuotes);
    }

    get staleHeading() {
        const { staleQuoteCount, staleQuotes } = this.cockpit;
        const shown = staleQuotes.length < staleQuoteCount ? `, the ${count(staleQuotes.length)} oldest of ${count(staleQuoteCount)}` : '';
        return `With the customer 15 days or more${shown}`;
    }

    get staleQuotes() {
        return this.cockpit.staleQuotes.map((quote) => {
            const waited = daysBetween(quote.issuedDate, this.cockpit.today);
            return {
                ...quote,
                ...this.row('pipeline', quote.recordId),
                saleName: keepTogether(quote.saleName),
                premiumLabel: money(quote.premium),
                waitedLabel: `Sent ${plural(waited, 'day')} ago`,
                waitedClass: waited >= OVERDUE_QUOTE_DAYS ? 'c-chip c-chip_alert' : 'c-chip c-chip_watch',
                issuedLabel: fullDate(quote.issuedDate),
                validLabel: quote.validUntil ? fullDate(quote.validUntil) : 'Not set',
                customerLabel: quote.accountName ?? 'Not recorded'
            };
        });
    }

    get hasStaleQuotes() {
        return this.cockpit.staleQuotes.length > 0;
    }

    // ------------------------------------------------------------------ underwriting

    get underwritingSummary() {
        const waiting = this.cockpit.referrals.length;
        return waiting === 0 ? 'No quotes are waiting on an underwriter.' : `${plural(waiting, 'quote waits', 'quotes wait')} on an underwriter. Largest premium first.`;
    }

    get referrals() {
        return this.cockpit.referrals.map((referral) => ({
            ...referral,
            ...this.row('underwriting', referral.recordId),
            saleName: keepTogether(referral.saleName),
            premiumLabel: money(referral.premium),
            reasons: referral.reasons.map((reason, index) => ({ key: `reason-${index}`, text: keepTogether(reason) })),
            hasReasons: referral.reasons.length > 0,
            hasMemo: Boolean(referral.memoRecommendation),
            memoChip: referral.memoRecommendation ? 'Memo drafted' : 'No memo yet',
            memoClass: referral.memoRecommendation ? 'c-chip c-chip_good' : 'c-chip',
            memoHeadline: keepTogether(referral.memoHeadline),
            customerLabel: referral.accountName ?? 'Not recorded',
            lineLabel: referral.lineOfBusiness ?? 'Not recorded'
        }));
    }

    get shownReferrals() {
        return this.paged('underwriting', this.referrals);
    }

    get hasReferrals() {
        return this.cockpit.referrals.length > 0;
    }

    // ------------------------------------------------------------------ navigation

    handleOpen(event) {
        // A modified click on a link is left to the browser, so the record can be opened in a new tab.
        if (event.currentTarget.tagName === 'A') {
            if (event.metaKey || event.ctrlKey || event.shiftKey) {
                return;
            }
            event.preventDefault();
        }
        const { recordId, object: objectApiName } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    handleViewAll(event) {
        const { view } = event.currentTarget.dataset;
        const pages = {
            tasks: { type: 'standard__navItemPage', attributes: { apiName: TASKS_TAB } },
            claims: list('Case', 'Open_Claims'),
            renewals: list('Policy__c', 'Renewals_Next_60_Days'),
            sales: list('Opportunity', 'Open_Policy_Sales'),
            waiting: list('Quote', 'Waiting_15_Days'),
            quotes: list('Quote', 'Open_Quotes')
        };
        this[NavigationMixin.Navigate](pages[view]);
    }
}
