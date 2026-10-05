import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import getWords from '@salesforce/apex/AntsuranceClaudeController.getWords';
import { loadBrandFonts } from 'c/antsuranceFonts';

// The tab's own name, for putting its address back once a handed-over question has been sent.
const TAB = 'Antsurance_Claude';
// Another page hands a question over in this part of the address.
const ASK_PARAM = 'c__ask';

// What the chat does, in the order people meet it.
const ABILITIES = [
    { icon: 'utility:database', name: 'Answer from live records', line: 'Read with your own access' },
    { icon: 'utility:chart', name: 'Draw the answer', line: 'Charts, cards, lists and timelines' },
    { icon: 'utility:image', name: 'Read photos and PDFs', line: 'Attach, paste or drop them in' },
    { icon: 'utility:check', name: 'Prepare changes for your OK', line: 'Saved or sent only by you' }
];
const BROWSER_TITLE = 'Ask Claude | Salesforce';

/** The Ask Claude tab: the chat on a page of its own, with what it can do and questions to try beside it. */
export default class AntsuranceClaudePage extends NavigationMixin(LightningElement) {
    abilities = ABILITIES.map((ability, index) => ({ ...ability, id: `ability-${index}` }));
    // Questions to try: a short label for the list, what Claude draws in reply, and the full question sent to the chat.
    // They depend on what the org holds, so they come from Apex (AntsuranceClaudeModel) with the chat's other words.
    questions = [];

    @wire(getWords)
    wiredWords({ data }) {
        if (data) {
            this.questions = data.questions.map((question, index) => ({ id: `question-${index}`, label: question.title, kind: question.detail, prompt: question.prompt }));
        }
    }

    // A question handed over in the address, waiting for the chat to be on the page; and the last one sent.
    pendingAsk;
    sentAsk;

    /**
     * Another page can open this tab with a question, for example Home:
     * { type: 'standard__navItemPage', attributes: { apiName: 'Antsurance_Claude' }, state: { c__ask: '...' } }.
     * The question starts a new chat and is sent once; coming back to the tab does not send it again.
     */
    @wire(CurrentPageReference)
    wiredPage(reference) {
        const ask = reference?.state?.[ASK_PARAM]?.trim();
        if (!ask) {
            // The address is clean again, so the same question can be handed over another time.
            this.sentAsk = undefined;
            return;
        }
        if (ask !== this.sentAsk) {
            this.pendingAsk = ask;
            this.sendPending();
        }
    }

    connectedCallback() {
        loadBrandFonts(this);
        // A tab that is a component is named "Lightning Experience" in the browser a moment after it opens,
        // so the name is set now and once more shortly after.
        document.title = BROWSER_TITLE;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.titleTimer = setTimeout(() => {
            if (this.isConnected) {
                document.title = BROWSER_TITLE;
            }
        }, 1500);
    }

    disconnectedCallback() {
        clearTimeout(this.titleTimer);
    }

    renderedCallback() {
        this.sendPending();
    }

    sendPending() {
        const chat = this.refs?.chat;
        if (!this.pendingAsk || !chat) {
            return;
        }
        const ask = this.pendingAsk;
        this.pendingAsk = undefined;
        this.sentAsk = ask;
        chat.startWith(ask);
        // Take the question out of the address, so a reload or a return to the tab starts clean.
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: TAB } }, true);
    }

    /** Sends one of the suggested questions to the chat as if it had been typed. */
    handleAsk(event) {
        this.refs.chat.ask(event.currentTarget.dataset.prompt);
    }
}
