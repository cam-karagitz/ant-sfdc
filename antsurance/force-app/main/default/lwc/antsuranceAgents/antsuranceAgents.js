import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRoster from '@salesforce/apex/AntsuranceAgentsController.getRoster';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { tidyEnding } from 'c/antsuranceText';

const BROWSER_TITLE = 'Claude at work | Salesforce';
const RECENT_PAGE_SIZE = 4;
const TRACE_PAGE_SIZE = 4;
const MANAGED = 'managed';
// How a job runs, in the few words the roster has room for.
const RUNS_SHORT = { managed: 'On a harness', loop: 'Tool loop', pipeline: 'Pipeline', single: 'Single call' };
const RUNS_LOWER = { loop: 'a tool loop built here, with a cap on its rounds', pipeline: 'a fixed pipeline of calls', single: 'a single call' };
const LOOP_LABELS = ['Reads', 'Works out', 'Prepares', 'A person decides'];
const RULE_CHIPS = {
    alone: { chip: 'Does it alone', chipClass: 'c-chip c-chip_alone' },
    person: { chip: 'Waits for a person', chipClass: 'c-chip c-chip_person' },
    off: { chip: 'Switched off', chipClass: 'c-chip c-chip_off' }
};
// Home with Claude's desk in view. The app's own Home reads the parameter; the Home tab would open a second Home.
const DESK_URL = '/lightning/page/home?c__show=desk';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function plural(count, one, many) {
    return `${count} ${count === 1 ? one : many}`;
}

function clock(date) {
    const hours = date.getHours();
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${hours % 12 === 0 ? 12 : hours % 12}:${minutes} ${hours < 12 ? 'AM' : 'PM'}`;
}

/** "Today at 6:00 PM", "Yesterday at 9:15 AM" or "Oct 2 at 4:30 PM", the way the claim cards write a date. */
function when(value) {
    if (!value) {
        return '';
    }
    const date = new Date(value);
    const today = new Date();
    const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    const daysAgo = Math.floor((startOfToday - new Date(date.getFullYear(), date.getMonth(), date.getDate())) / 86400000);
    const day = daysAgo === 0 ? 'Today' : daysAgo === 1 ? 'Yesterday' : `${MONTHS[date.getMonth()]} ${date.getDate()}`;
    return `${day} at ${clock(date)}`.replace(/ (AM|PM)$/, ' $1');
}

function day(value) {
    if (!value) {
        return '';
    }
    const [year, month, dayOfMonth] = String(value).split('-').map(Number);
    return `${MONTHS[month - 1]} ${dayOfMonth}, ${year}`;
}

/**
 * The "Claude at work" tab. The Claude work in this org shown as one job per row: how it really runs
 * (an agent on a harness, a tool loop built here, a pipeline or a single call), what it reads and
 * prepares, what it may do alone and what waits for a person, what it did (counted from records,
 * or not shown at all), and how it scored when tested. The word "agent" is used only for a job a
 * harness runs. The page only reads.
 */
export default class AntsuranceAgents extends NavigationMixin(LightningElement) {
    data;
    errorMessage;
    chosenKey;
    deskUrl = DESK_URL;
    tab = 'job';
    recentPageNumber = 0;
    recentPageSize = RECENT_PAGE_SIZE;
    tracePageNumber = 0;
    tracePageSize = TRACE_PAGE_SIZE;
    bones = [1, 2, 3, 4, 5, 6, 7, 8];

    connectedCallback() {
        loadBrandFonts(this);
        this.nameBrowserTab();
        this.load();
    }

    disconnectedCallback() {
        clearTimeout(this.titleTimer);
    }

    /** A tab that is a component is named "Lightning Experience" a moment after it opens, so the name is set twice. */
    nameBrowserTab() {
        document.title = BROWSER_TITLE;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.titleTimer = setTimeout(() => {
            if (this.isConnected) {
                document.title = BROWSER_TITLE;
            }
        }, 1500);
    }

    async load() {
        try {
            this.data = await getRoster();
            this.chosenKey = this.data.agents.length > 0 ? this.data.agents[0].key : undefined;
            this.errorMessage = undefined;
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The agents could not be read. Reload the page to try again.';
        }
    }

    get isLoading() {
        return !this.data && !this.errorMessage;
    }

    get isReady() {
        return Boolean(this.data) && this.data.agents.length > 0;
    }

    get headline() {
        if (!this.data) {
            return 'One job at a time. Each reads, prepares, and leaves the decision to a person.';
        }
        const jobs = plural(this.data.agents.length, 'job', 'jobs');
        const harness =
            this.data.harnessed > 0
                ? `${this.data.harnessed === 1 ? 'One runs' : `${this.data.harnessed} run`} as an agent on a harness. The rest are single calls, pipelines and one tool loop.`
                : 'None runs on an agent harness in this org: they are single calls, pipelines and one tool loop.';
        return `${jobs}, each with its own reading and its own tools. ${harness}`;
    }

    get modelLine() {
        if (!this.data?.model) {
            return undefined;
        }
        return `Runs on ${this.data.model}${this.data.fastMode ? ', fast mode' : ''}`;
    }

    get figures() {
        const counted = this.data.agents.filter(agent => agent.isCounted).length;
        return [
            { label: 'Jobs', value: this.data.agents.length, note: 'each with its own tools' },
            { label: 'On an agent harness', value: this.data.harnessed, note: this.data.harnessed > 0 ? 'Claude Managed Agents' : 'not set up in this org' },
            { label: 'Work today', value: this.data.today, note: `${this.data.week} in 7 days, from ${plural(counted, 'job', 'jobs')}` },
            { label: 'Waiting for a person', value: this.data.waiting, note: "on Claude's desk" },
            { label: 'Tested', value: `${this.data.tested} of ${this.data.agents.length}`, note: 'have an accuracy test on file' }
        ];
    }

    get roster() {
        return this.data.agents.map(agent => {
            const isChosen = agent.key === this.chosenKey;
            return {
                key: agent.key,
                name: agent.name,
                icon: agent.icon,
                waiting: agent.waiting,
                isAgent: agent.runs === MANAGED,
                note: agent.isCounted ? `${RUNS_SHORT[agent.runs]}, ${agent.today} today` : RUNS_SHORT[agent.runs],
                tileClass: `c-ui-tile c-ui-tile_${agent.tint}`,
                rowClass: `c-row c-ui-focus${isChosen ? ' c-row_chosen' : ''}`,
                selected: isChosen ? 'true' : 'false',
                tabIndex: isChosen ? '0' : '-1'
            };
        });
    }

    get agent() {
        const chosen = this.data.agents.find(agent => agent.key === this.chosenKey) ?? this.data.agents[0];
        const counts = [
            { label: 'Today', value: chosen.today },
            { label: 'Last 7 days', value: chosen.week }
        ];
        if (chosen.waiting > 0 || chosen.rules.some(rule => rule.isSetting)) {
            counts.push({ label: 'Waiting for a person', value: chosen.waiting });
        }
        const hasApproved = chosen.approved !== undefined && chosen.approved !== null;
        const hasDismissed = chosen.dismissed !== undefined && chosen.dismissed !== null;
        if (chosen.key === 'coverage' && hasApproved) {
            counts.push({ label: 'Confirmed by an adjuster', value: chosen.approved });
        } else if (hasApproved || hasDismissed) {
            // One cell for what people decided, so the row never leaves a figure alone on a second line.
            // Each count stays with its word: in a narrow cell the line breaks at the comma, not before "dismissed".
            counts.push({ label: 'Decided by a person', value: `${chosen.approved ?? 0}\u00a0approved, ${chosen.dismissed ?? 0}\u00a0dismissed`, isWords: true });
        }
        counts.forEach(count => {
            count.valueClass = count.isWords ? 'c-counts__value c-counts__value_words' : 'c-counts__value';
        });
        return {
            ...chosen,
            // Sentences are kept from ending on one or two words where the panel is narrow.
            job: tidyEnding(chosen.job),
            runsLine: tidyEnding(chosen.runsLine),
            harnessLine: tidyEnding(chosen.harnessLine),
            notCountedWhy: tidyEnding(chosen.notCountedWhy),
            largeTileClass: `c-ui-tile c-ui-tile_large c-ui-tile_${chosen.tint}`,
            isAgent: chosen.runs === MANAGED,
            runsClass: `c-chip ${chosen.runs === MANAGED ? 'c-chip_agent' : 'c-chip_runs'}`,
            runsLower: RUNS_LOWER[chosen.runs],
            traceWhen: chosen.traceOf ? when(chosen.traceOf.happenedAt) : '',
            traceRows: chosen.trace.map((words, index) => ({ key: `${index}`, words })),
            start: chosen.start,
            stepRows: chosen.steps.map((text, index) => ({
                label: LOOP_LABELS[index],
                text,
                stepClass: index === LOOP_LABELS.length - 1 ? 'c-loop__step c-loop__step_person' : 'c-loop__step'
            })),
            facts: [
                { label: 'Reads', items: chosen.reads },
                { label: 'Uses', items: chosen.tools },
                { label: 'Prepares', items: chosen.prepares }
            ],
            ruleRows: chosen.rules.map(rule => ({ ...rule, detail: tidyEnding(rule.detail), ...RULE_CHIPS[rule.mode] })),
            counts,
            recentRows: chosen.recent.map((item, index) => ({ ...item, key: `${index}`, when: when(item.happenedAt) })),
            testRows: chosen.tests.map(test => ({
                ...test,
                measured: tidyEnding(test.measured),
                caveat: tidyEnding(test.caveat),
                meta: `Run ${day(test.runOn)}. In the project at ${test.source}.`
            }))
        };
    }

    get tabs() {
        const chosen = this.agent;
        const alone = chosen.rules.filter(rule => rule.mode === 'alone').length;
        return [
            { value: 'job', label: 'The job' },
            { value: 'rules', label: 'On its own', count: `${alone} of ${chosen.rules.length}`, title: `${alone} of ${chosen.rules.length} things it does without a person` },
            // A job that leaves nothing on a record to count has no "What it did" tab: it would hold one sentence.
            ...(chosen.isCounted ? [{ value: 'work', label: 'What it did', count: chosen.week }] : []),
            { value: 'tests', label: 'Tested', count: chosen.tests.length, tone: chosen.tests.length === 0 ? 'watch' : undefined },
            { value: 'harness', label: chosen.isAgent ? 'The agent' : 'On a harness' }
        ];
    }

    get showsJob() {
        return this.tab === 'job';
    }

    get showsRules() {
        return this.tab === 'rules';
    }

    get showsWork() {
        return this.tab === 'work';
    }

    get showsTests() {
        return this.tab === 'tests';
    }

    get showsHarness() {
        return this.tab === 'harness';
    }

    get hasTrace() {
        return this.agent.traceRows.length > 0;
    }

    get traceTotal() {
        return this.agent.traceRows.length;
    }

    get tracePage() {
        const start = this.tracePageNumber * TRACE_PAGE_SIZE;
        return this.agent.traceRows.slice(start, start + TRACE_PAGE_SIZE);
    }

    /** The number the visible steps start at, so page two of a trace reads 6, 7, 8. */
    get traceStart() {
        return this.tracePageNumber * TRACE_PAGE_SIZE + 1;
    }

    get hasRecent() {
        return this.agent.recentRows.length > 0;
    }

    get recentTotal() {
        return this.agent.recentRows.length;
    }

    get recentPage() {
        const start = this.recentPageNumber * RECENT_PAGE_SIZE;
        return this.agent.recentRows.slice(start, start + RECENT_PAGE_SIZE);
    }

    get hasTests() {
        return this.agent.tests.length > 0;
    }

    choose(key) {
        // Another job opens on what it is, whichever tab the last one was left on.
        if (key !== this.chosenKey) {
            this.tab = 'job';
        }
        this.chosenKey = key;
        this.recentPageNumber = 0;
        this.tracePageNumber = 0;
    }

    handlePick(event) {
        this.choose(event.currentTarget.dataset.key);
    }

    /** Up and Down move through the roster and choose as they go, as a list of tabs does. */
    handleRosterKey(event) {
        const keys = this.data.agents.map(agent => agent.key);
        const index = keys.indexOf(this.chosenKey);
        const moves = { ArrowDown: index + 1, ArrowRight: index + 1, ArrowUp: index - 1, ArrowLeft: index - 1, Home: 0, End: keys.length - 1 };
        if (!(event.key in moves)) {
            return;
        }
        event.preventDefault();
        const next = keys[(moves[event.key] + keys.length) % keys.length];
        this.choose(next);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(`[data-key="${next}"]`)?.focus(), 0);
    }

    handleTab(event) {
        this.tab = event.detail.value;
    }

    handlePage(event) {
        this.recentPageNumber = event.detail.page;
    }

    handleTracePage(event) {
        this.tracePageNumber = event.detail.page;
    }

    handleOpen(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url: event.currentTarget.dataset.url } });
    }
}
