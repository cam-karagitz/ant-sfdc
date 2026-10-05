import { LightningElement, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import LOCALE from '@salesforce/i18n/locale';
import getMyOpenTasks from '@salesforce/apex/AntsuranceTasksController.getMyOpenTasks';
import completeTask from '@salesforce/apex/AntsuranceWorkController.completeTask';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { kindIcon, taskIcon } from 'c/antsuranceIcons';

// How long after a group opens a click on a task's complete circle is taken as a slip.
const BROWSER_TITLE = 'Tasks | Salesforce';
const SETTLE_MS = 700;
const MS_PER_DAY = 86400000;
// After New Task opens there is no signal when it is saved, so the list looks again a few times.
const RECHECKS_AFTER_NEW = 10;
const RECHECK_EVERY_MS = 4000;

// What a task is about, as the shared icon mapping names it.
const KIND_NAMES = { 'policy sale': 'sale', customer: 'person' };
// A call, an email or a meeting shows as that; any other task shows what it is about.
const VERB_ICON = 'utility:task';

const GROUPS = [
    { key: 'overdue', label: 'Overdue', pagerLabel: 'overdue tasks' },
    { key: 'today', label: 'Today', pagerLabel: 'tasks due today' },
    { key: 'week', label: 'This week', pagerLabel: 'tasks due this week' },
    { key: 'later', label: 'Later', pagerLabel: 'later tasks' }
];
// One group is open at a time and shows this many rows a page, so the tab is about a screen tall
// however many tasks are open.
const PAGE_SIZE = 6;

/**
 * The Tasks tab: every open task I own, grouped by when it is due, each named in full with who and
 * what it is about, and a tick to complete it. It stands in for the stock Tasks tab, which draws
 * as a narrow strip on some loads and names a claim by its number.
 */
export default class AntsuranceTasks extends NavigationMixin(LightningElement) {
    board;
    boardResult;
    errorMessage;
    isCompleting = false;
    // Six rows of bones: about a screen of the list that is coming.
    bones = [1, 2, 3, 4, 5, 6];
    pageSize = PAGE_SIZE;
    /**
     * The group the reader opened, or '' when they closed them all. Until they choose, the most
     * pressing group that has tasks is open.
     */
    // The groups that are open, by key. Unset until the reader opens or closes one: the first group is then open.
    openKeys;
    settlingUntil = 0;
    /** The page each group is on, by group key, counted from 0. */
    pages = {};
    recheckTimer;
    rechecksLeft = 0;

    connectedCallback() {
        loadBrandFonts(this);
        this.nameBrowserTab();
    }

    disconnectedCallback() {
        this.stopRechecking();
        clearTimeout(this.titleTimer);
    }

    /**
     * A tab that is a component gets "Lightning Experience" as its browser tab name. Lightning sets that a
     * moment after the page opens, so the name is set now and once more shortly after. Leaving the page
     * names the browser tab again from the page that opens.
     */
    nameBrowserTab() {
        document.title = BROWSER_TITLE;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.titleTimer = setTimeout(() => {
            if (this.isConnected) {
                document.title = BROWSER_TITLE;
            }
        }, 1500);
    }

    @wire(getMyOpenTasks)
    wiredBoard(result) {
        this.boardResult = result;
        if (result.data) {
            this.board = result.data;
            this.errorMessage = undefined;
        } else if (result.error) {
            this.errorMessage = result.error.body?.message ?? 'Your tasks could not be loaded.';
        }
    }

    /** Coming back to the tab asks for fresh tasks, since work elsewhere opens and closes them. */
    @wire(CurrentPageReference)
    wiredPage() {
        this.refresh();
    }

    refresh() {
        return this.boardResult ? refreshApex(this.boardResult) : Promise.resolve();
    }

    get isLoading() {
        return !this.board && !this.errorMessage;
    }

    get summary() {
        if (!this.board) {
            return 'Loading your tasks';
        }
        const { openCount, overdueCount } = this.board;
        if (openCount === 0) {
            return 'Nothing open';
        }
        return overdueCount > 0 ? `${openCount} open, ${overdueCount} overdue` : `${openCount} open`;
    }

    get isEmpty() {
        return Boolean(this.board) && this.board.tasks.length === 0;
    }

    /** More tasks are open than the page lists. */
    get moreNote() {
        if (!this.board || this.board.openCount <= this.board.tasks.length) {
            return undefined;
        }
        return `Showing the ${this.board.tasks.length} due soonest of ${this.board.openCount}.`;
    }

    daysFromToday(dateValue) {
        const today = new Date(`${this.board.today}T00:00:00`).getTime();
        return Math.round((new Date(`${dateValue}T00:00:00`).getTime() - today) / MS_PER_DAY);
    }

    /** The groups that have tasks, in order: overdue, today, the next seven days, then everything later or undated. */
    get groups() {
        if (!this.board) {
            return [];
        }
        const near = new Intl.DateTimeFormat(LOCALE, { weekday: 'short', month: 'short', day: 'numeric' });
        const far = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric' });
        const rows = { overdue: [], today: [], week: [], later: [] };
        this.board.tasks.forEach((task) => {
            let group = 'later';
            let dueLabel = 'No date';
            let tone = 'later';
            if (task.dueDate) {
                const days = this.daysFromToday(task.dueDate);
                const date = new Date(`${task.dueDate}T00:00:00`);
                if (days < 0) {
                    group = 'overdue';
                    dueLabel = days === -1 ? '1 day overdue' : `${-days} days overdue`;
                    tone = 'overdue';
                } else if (days === 0) {
                    group = 'today';
                    dueLabel = 'Today';
                    tone = 'today';
                } else if (days <= 7) {
                    group = 'week';
                    dueLabel = days === 1 ? 'Tomorrow' : near.format(date);
                } else {
                    dueLabel = far.format(date);
                }
            }
            const isHigh = task.priority === 'High';
            const verb = taskIcon(task.subject);
            const kind = String(task.relatedKind ?? '').toLowerCase();
            rows[group].push({
                ...task,
                icon: verb.name === VERB_ICON && kind ? kindIcon(KIND_NAMES[kind] ?? kind) : verb,
                rowClass: `c-row c-row_${tone} c-ui-open`,
                dueLabel,
                dueClass: `c-due c-due_${tone}`,
                isHigh,
                priorityClass: isHigh ? 'c-priority c-priority_high' : 'c-priority',
                // Most tasks are Normal, so only the ones that are not say so.
                priorityLabel: task.priority && task.priority !== 'Normal' ? `${task.priority} priority` : '',
                hasAbout: Boolean(task.relatedName || task.contactName),
                hasBoth: Boolean(task.relatedName && task.contactName),
                completeLabel: `Mark complete: ${task.subject}`,
                url: `/lightning/r/Task/${task.recordId}/view`,
                relatedUrl: task.relatedId ? `/lightning/r/${task.relatedId}/view` : undefined,
                contactUrl: task.contactId ? `/lightning/r/${task.contactId}/view` : undefined
            });
        });
        const present = GROUPS.filter((group) => rows[group.key].length > 0);
        // The first group is open until the reader chooses. See handleGroupToggle for which stay open after that.
        const open = this.openKeys ?? (present.length > 0 ? [present[0].key] : []);
        return present.map((group) => {
            const count = rows[group.key].length;
            // Completing the last task on a page steps back to the page before it.
            const page = Math.min(this.pages[group.key] ?? 0, Math.ceil(count / PAGE_SIZE) - 1);
            return {
                ...group,
                count,
                page,
                isOpen: open.includes(group.key),
                // What is first in a closed group, so its header says more than a number.
                summary: `First: ${rows[group.key][0].subject}`,
                sectionClass: `c-group c-group_${group.key}`,
                pageRows: rows[group.key].slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)
            };
        });
    }

    get hasGroups() {
        return this.groups.length > 0;
    }

    /**
     * Opening a group closes any open group below it and leaves the ones above it open. Closing a group
     * above the one clicked would pull every header up the page, and a page too short to scroll cannot
     * put the clicked header back: a task's complete circle would land under the pointer. This way the
     * header that was clicked never moves. Closing a group is the reader's own click on its header.
     */
    handleGroupToggle(event) {
        const header = event.currentTarget;
        const key = header.dataset.key;
        const before = header.getBoundingClientRect().top;
        this.settlingUntil = Date.now() + SETTLE_MS;
        const order = GROUPS.map((group) => group.key);
        const open = this.openKeys ?? this.groups.filter((group) => group.isOpen).map((group) => group.key);
        this.openKeys = event.detail.open
            ? [...open.filter((other) => order.indexOf(other) < order.indexOf(key)), key]
            : open.filter((other) => other !== key);
        // Belt and braces: if anything above did change height, scroll the header back to where it was.
        // A timer, not an animation frame: a tab that is not in front draws no frames.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const moved = header.getBoundingClientRect().top - before;
            if (Math.abs(moved) < 1) {
                return;
            }
            const scroller = this.scrollerOf(header);
            if (scroller) {
                scroller.scrollTop += moved;
            } else {
                window.scrollBy(0, moved);
            }
        }, 0);
    }

    /** The nearest thing that scrolls around an element, looking out through component boundaries. */
    scrollerOf(element) {
        let node = element;
        while (node) {
            if (node instanceof Element) {
                const overflow = getComputedStyle(node).overflowY;
                if ((overflow === 'auto' || overflow === 'scroll') && node.scrollHeight > node.clientHeight + 1) {
                    return node;
                }
            }
            node = node.parentNode || node.host;
        }
        return null;
    }

    handlePage(event) {
        this.pages = { ...this.pages, [event.currentTarget.dataset.key]: event.detail.page };
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

    /** A click anywhere on a row that is not one of its links or its tick opens the task. */
    handleRowClick(event) {
        if (event.target.closest('a, button')) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }

    async handleComplete(event) {
        event.stopPropagation();
        // A group has just opened or closed and the rows are still settling under the pointer: a click that
        // lands on a circle now was aimed at something else.
        if (Date.now() < this.settlingUntil) {
            return;
        }
        this.isCompleting = true;
        this.errorMessage = undefined;
        try {
            await completeTask({ taskId: event.currentTarget.dataset.recordId });
            await this.refresh();
        } catch (error) {
            this.errorMessage = error.body?.message ?? 'That task could not be completed.';
        } finally {
            this.isCompleting = false;
        }
    }

    handleNew() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Task', actionName: 'new' },
            state: { navigationLocation: 'RELATED_LIST' }
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

    stopRechecking() {
        if (this.recheckTimer) {
            clearInterval(this.recheckTimer);
            this.recheckTimer = undefined;
        }
    }

    handleAll(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Task', actionName: 'list' },
            state: { filterName: 'OpenTasks' }
        });
    }
}
