import { LightningElement, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getCockpit from '@salesforce/apex/AntsuranceCockpitController.getCockpit';

// How long Home waits for itself to be loaded and in front before bringing the desk into view: 20 looks, a quarter second apart.
const ARRIVAL_TRIES = 20;
const ARRIVAL_WAIT_MS = 250;

/**
 * The Antsurance Home page, laid out as a cockpit: a command bar, six figures beside how the loss
 * ratio built, Claude's briefing beside a rail (what to watch, and quick actions), and a tabbed workspace. One cached Apex call feeds all of it, so
 * the page paints at once from the cache; fresh data is asked for when the page first renders, when
 * the person navigates back to Home, when the browser tab comes back into view, and after anything
 * on the page changes a record.
 */
export default class AntsuranceHome extends LightningElement {
    cockpit;
    cockpitResult;
    /** The briefing just written, shown until the reload brings back the stored copy. */
    freshBriefing;
    errorMessage;
    hasRendered = false;
    /** What a link asked Home to bring into view when it arrives: "desk", from /lightning/page/home?c__show=desk. */
    showOnArrival;
    handleVisibility = () => {
        if (document.visibilityState === 'visible') {
            this.refresh();
        }
    };

    @wire(getCockpit)
    wiredCockpit(result) {
        this.cockpitResult = result;
        if (result.data) {
            this.cockpit = result.data;
            this.errorMessage = undefined;
        } else if (result.error) {
            this.errorMessage = result.error.body?.message ?? 'Home could not be loaded.';
        }
    }

    // Lightning keeps this page alive while the person visits other tabs; coming back delivers a new page reference.
    @wire(CurrentPageReference)
    wiredPage(pageReference) {
        // "Open Claude's desk" on Claude at Work, and "Change on the desk", arrive as Home with c__show=desk.
        if (pageReference?.state?.c__show === 'desk') {
            this.showOnArrival = 'desk';
        }
        if (this.hasRendered) {
            this.refresh();
            this.arrive();
        }
    }

    connectedCallback() {
        document.addEventListener('visibilitychange', this.handleVisibility);
    }

    renderedCallback() {
        if (!this.hasRendered) {
            this.hasRendered = true;
            this.refresh();
        }
        this.arrive();
    }

    /**
     * Brings the desk into view for a link that asked for it, once. It waits for the page to hold its
     * figures (their arrival moves everything below them) and to be the page in front: Lightning keeps
     * Home alive behind other tabs, where nothing can be scrolled to.
     */
    arrive(triesLeft = ARRIVAL_TRIES) {
        if (this.showOnArrival !== 'desk') {
            return;
        }
        clearTimeout(this.arrivalTimer);
        const workspace = this.refs.workspace;
        if (!this.cockpit || !workspace || workspace.getBoundingClientRect().width === 0) {
            if (triesLeft > 0) {
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this.arrivalTimer = setTimeout(() => this.arrive(triesLeft - 1), ARRIVAL_WAIT_MS);
            }
            return;
        }
        this.showOnArrival = undefined;
        this.handleOpenDesk();
    }

    disconnectedCallback() {
        clearTimeout(this.arrivalTimer);
        document.removeEventListener('visibilitychange', this.handleVisibility);
    }

    /** Reloads everything on the page from Salesforce. */
    refresh() {
        return this.cockpitResult ? refreshApex(this.cockpitResult) : Promise.resolve();
    }

    /**
     * The briefing the card and the rail both show. The stored copy wins once it is at least as new
     * as the one just written, because only it knows what has been done since.
     */
    get briefing() {
        const stored = this.cockpit?.briefing;
        const fresh = this.freshBriefing;
        if (fresh && (!stored || new Date(stored.writtenAt) < new Date(fresh.writtenAt))) {
            return fresh;
        }
        return stored;
    }

    handleBriefed(event) {
        this.freshBriefing = event.detail;
        this.refresh();
    }

    /** Something on the page changed a record. Everything reloads; the desk too, unless the change came from it. */
    handleChanged(event) {
        this.refresh();
        if (event?.detail?.from !== 'desk') {
            this.refs.workspace?.refreshDesk();
        }
    }

    /** The briefing sends the person to Claude's desk: show that tab and bring it into view. */
    handleOpenDesk() {
        const workspace = this.refs.workspace;
        if (!workspace) {
            return;
        }
        workspace.showTab('desk');
        // Once the desk has drawn, so one press lands on it: the tab change redraws the workspace in the next
        // microtask, and this runs after it. It jumps, because a glide here is cut short a few pixels in.
        Promise.resolve()
            .then(() => Promise.resolve())
            .then(() => {
                workspace.scrollIntoView({ behavior: 'auto', block: 'start' });
                workspace.focusTab();
            });
    }
}
