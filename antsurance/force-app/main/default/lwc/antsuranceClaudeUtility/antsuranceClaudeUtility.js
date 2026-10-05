import { LightningElement, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { EnclosingUtilityId, minimize, updatePanel } from 'lightning/platformUtilityBarApi';

const RECORD_ID = /^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/;
// The tab that is the chat on a page of its own.
const CHAT_TAB = 'Antsurance_Claude';
// Tallest and shortest the panel may be, and what the window keeps for itself: the Salesforce header and
// navigation bar above the panel, and the utility bar and a margin below it.
const PANEL_MAX = 640;
const PANEL_MIN = 360;
const CHROME = 188;
// On a record page the panel also stops short of the record's title, which sits just under the
// navigation bar: the person asking about a record can still see which record it is.
const RECORD_TITLE = 92;
// The panel's own title bar, which is part of its height: measured at 51 pixels.
const PANEL_HEADER = 52;

/**
 * Claude in the utility bar. A utility item is not handed a record Id, so this reads
 * the page the user is on and passes the open record, if any, to the chat.
 */
export default class AntsuranceClaudeUtility extends LightningElement {
    pageReference;

    @wire(CurrentPageReference)
    wiredPage(pageReference) {
        this.pageReference = pageReference;
        // A record page and a list or Home leave the panel different room.
        this.fitPanel();
    }

    utilityId;
    onResize;
    resizeTimer;

    @wire(EnclosingUtilityId)
    wiredUtilityId(id) {
        this.utilityId = id;
        this.fitPanel();
    }

    connectedCallback() {
        this.onResize = () => {
            clearTimeout(this.resizeTimer);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.resizeTimer = setTimeout(() => this.fitPanel(), 150);
        };
        window.addEventListener('resize', this.onResize);
        this.fitPanel();
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.onResize);
        clearTimeout(this.resizeTimer);
    }

    /**
     * The panel's height is one number in the app's setup, and a window can be shorter than it: the
     * panel then rides up over the Salesforce header. So the panel is sized to the window here, between
     * the navigation bar and the utility bar, and the chat is told how tall the panel's body is.
     */
    fitPanel() {
        const kept = CHROME + (this.pageReference?.type === 'standard__recordPage' ? RECORD_TITLE : 0);
        const height = Math.max(PANEL_MIN, Math.min(PANEL_MAX, window.innerHeight - kept));
        this.template.host.style.setProperty('--ants-panel-body', `${height - PANEL_HEADER}px`);
        if (this.utilityId) {
            // The attribute is `height`, in pixels; `heightPX` is refused as unsupported.
            Promise.resolve()
                .then(() => updatePanel(this.utilityId, { height }))
                .catch(() => {
                    // Outside a utility bar there is no panel to size; the chat keeps its own fallback height.
                });
        }
    }

    handleHide() {
        if (this.utilityId) {
            minimize(this.utilityId);
        }
    }

    /** On the Ask Claude tab the chat is already on the page, so the panel does not show a second one. */
    get isOnChatTab() {
        return this.pageReference?.type === 'standard__navItemPage' && this.pageReference?.attributes?.apiName === CHAT_TAB;
    }

    /** The panel's chat stays in place while hidden, so its conversation is still there on the next page. */
    get chatClass() {
        return this.isOnChatTab ? 'slds-hide' : '';
    }

    get recordId() {
        const recordId = this.pageReference?.attributes?.recordId;
        return RECORD_ID.test(recordId ?? '') ? recordId : undefined;
    }
}
