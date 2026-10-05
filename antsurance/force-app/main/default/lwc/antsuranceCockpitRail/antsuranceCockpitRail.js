import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import AutonomyPanel from 'c/antsuranceDeskAutonomy';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether, tidyEnding } from 'c/antsuranceText';

const ACTIONS = [
    { key: 'task', label: 'New task', icon: 'utility:task', page: { type: 'standard__objectPage', attributes: { objectApiName: 'Task', actionName: 'new' } } },
    { key: 'lead', label: 'New lead', icon: 'utility:adduser', page: { type: 'standard__objectPage', attributes: { objectApiName: 'Lead', actionName: 'new' } } },
    { key: 'dashboards', label: 'Dashboards', icon: 'utility:chart', page: { type: 'standard__objectPage', attributes: { objectApiName: 'Dashboard', actionName: 'home' } } },
    { key: 'claude', label: 'Ask Claude', icon: 'utility:sparkles', page: { type: 'standard__navItemPage', attributes: { apiName: 'Antsurance_Claude' } } }
];

// The longest record name the rail holds on one line, in characters.
const LONGEST_NAME = 42;

/**
 * A record's name short enough for one line of the rail. A long one is built of parts ("Takahashi
 * Household - Personal Auto, Standard deductible": the customer, the sale, the quote), so it loses
 * its last part, and the one before, until it fits: "Takahashi Household - Personal Auto". The link
 * still opens the same record and gives the whole name on hover.
 */
function shortName(name) {
    let short = typeof name === 'string' ? name : '';
    while (short.length > LONGEST_NAME && /, | - /.test(short)) {
        short = short.slice(0, Math.max(short.lastIndexOf(', '), short.lastIndexOf(' - ')));
    }
    return short;
}

/**
 * The rail beside the briefing. When Claude has written one, its "keep an eye on" list sits here,
 * beside the things to do first; under it, the four things people start from Home.
 */
export default class AntsuranceCockpitRail extends NavigationMixin(LightningElement) {
    /** The briefing Home is showing, if there is one. */
    @api briefing;
    actions = ACTIONS;

    connectedCallback() {
        loadBrandFonts(this);
    }

    get watch() {
        return (this.briefing?.watch ?? []).map((item, index) => ({
            ...item,
            key: `watch-${index}`,
            label: keepTogether(item.label),
            detail: tidyEnding(item.detail),
            recordName: shortName(item.recordName),
            fullName: item.recordName,
            url: item.recordId ? `/lightning/r/${item.objectApiName}/${item.recordId}/view` : undefined
        }));
    }

    get hasWatch() {
        return this.watch.length > 0;
    }

    handleAction(event) {
        const target = ACTIONS.find((item) => item.key === event.currentTarget.dataset.key);
        this[NavigationMixin.Navigate](target.page);
    }

    /** Opens the panel that sets how far Claude goes on its own. Home reloads when it was changed. */
    async handleAutonomy() {
        const result = await AutonomyPanel.open({ size: 'small', label: 'What Claude may do' });
        if (result === 'saved') {
            this.dispatchEvent(new CustomEvent('changed'));
        }
    }

    handleOpen(event) {
        // A modified click is left to the browser, so the record can be opened in a new tab.
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        const { recordId, object: objectApiName } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }
}
