import { LightningElement, track } from 'lwc';
import getHome from '@salesforce/apex/AntsurancePortalController.getHome';
import getPolicy from '@salesforce/apex/AntsurancePortalController.getPolicy';
import getClaim from '@salesforce/apex/AntsurancePortalController.getClaim';
import getRequest from '@salesforce/apex/AntsurancePortalController.getRequest';
import basePath from '@salesforce/community/basePath';
import LOCKUP from '@salesforce/resourceUrl/antsuranceLockupOnWhite';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepLastWordsTogether } from 'c/antsurancePortalText';

/**
 * The site's pages. This component owns the router: anything that wants to go somewhere asks it, by page
 * name, through `go` (its own links, the `open` events of the cards and pages, and Claude's navigate action).
 * `record` pages need a record Id, which the server checks belongs to the customer before returning it.
 * `form` pages take an optional policy Id, to start the form on that policy.
 *
 * To add a page (a guided quote, say): name it here, draw it in the template under its own `is...` getter,
 * describe it in `screen` so Claude knows what is on it, and add its name to the page list in
 * AntsurancePortalClaude. Claude can then navigate to it, and fill and point at any form on it.
 */
const PAGES = {
    home: { title: 'Home', nav: 'home' },
    policies: { title: 'Your policies', nav: 'policies' },
    policy: { title: 'Policy', nav: 'policies', record: true },
    claims: { title: 'Your claims', nav: 'claims' },
    claim: { title: 'Claim', nav: 'claims', record: true },
    requests: { title: 'Your requests', nav: 'requests' },
    request: { title: 'Request', nav: 'requests', record: true },
    addDriver: { title: 'Add a driver', nav: 'requests', form: true },
    newRequest: { title: 'Ask for a change', nav: 'requests', form: true },
    newClaim: { title: 'File a claim', nav: 'claims', form: true },
    // The quote pages. A quote being answered reads like a form to Claude but lays itself out, price and all.
    quotes: { title: 'Get a quote', nav: 'quotes' },
    newQuote: { title: 'Your quote', nav: 'quotes', form: true, own: true },
    quote: { title: 'Quote', nav: 'quotes', record: true }
};
const NAV = [
    { page: 'home', label: 'Home' },
    { page: 'policies', label: 'Policies' },
    { page: 'claims', label: 'Claims' },
    { page: 'requests', label: 'Requests' },
    { page: 'quotes', label: 'Quotes' }
];
/** Rows on a page of a list. */
const PAGE_SIZE = 5;
/** A home suggestion's padding and border, left and right, and the gap between two of them, in pixels. */
const CHIP_CHROME = 26;
const CHIP_GAP = 8;
/** What happens after each form is sent, for the panel beside it. */
const NEXT_STEPS = {
    addDriver: ["You send the driver's details.", 'We check their driving record and work out any change in price.', 'We confirm it with you before anything takes effect.'],
    newRequest: ['You tell us what you need.', 'A person on our service team picks it up, usually within one business day.', 'We confirm the change with you.'],
    newClaim: ['You tell us what happened.', 'An adjuster contacts you within one business day.', 'We agree the repair or the payment with you.']
};

/**
 * The customer portal: a compact header, the pages, Claude as the page's right-hand companion, and a slim footer.
 *
 * Claude acts on the site through an action channel. The chat raises `actions`; this component carries each
 * one out where the customer can see it (navigate to a page, fill fields of the form on screen, point at a
 * field or section), says what it is doing in a line at the top of the page, and reports the result back to
 * the chat with `note`, so the conversation knows what happened. With every message the chat sends `screen`:
 * the page, the record, and the form's fields and their current values.
 */
export default class AntsurancePortalApp extends LightningElement {
    @track home;
    @track route = { page: 'home' };
    @track policy;
    @track claim;
    @track request;
    @track formState;
    /** The quote on screen, once its own component has loaded it. */
    quoteSeen;
    isLoading = true;
    failure;
    notFound = false;
    isChatOpen = false;
    isChatWide = false;
    /** Whether the conversation holds anything yet, which is when starting a new one is offered. */
    hasConversation = false;
    /** How Home's suggestions are laid out for the room they have: "row", "pairs" or "stack". */
    chipLayout = 'row';
    claimPage = 0;
    requestPage = 0;
    announcement;
    pointedSection;
    prompt = '';
    lockup = LOCKUP;
    spark = SPARK;
    announceTimer;

    connectedCallback() {
        loadBrandFonts(this);
        this.onHash = () => this.readHash();
        window.addEventListener('hashchange', this.onHash);
        this.onResize = () => this.fitChips();
        window.addEventListener('resize', this.onResize);
        this.load().then(() => {
            this.readHash();
            this.nameTab();
        });
    }

    disconnectedCallback() {
        window.removeEventListener('hashchange', this.onHash);
        window.removeEventListener('resize', this.onResize);
    }

    renderedCallback() {
        this.fitChips();
    }

    /**
     * Lays Home's suggestions out for the room they have, so the gaps between them are always even: one row
     * when they all fit; otherwise wrapped rows with each at its own width; and one column where a single
     * suggestion is wider than the room. It runs after each draw (the conversation
     * opening or widening changes the room) and when the window changes size.
     */
    fitChips() {
        const holder = this.template.querySelector('.c-hero__chips');
        const room = holder?.clientWidth;
        if (!room) {
            return;
        }
        const widths = Array.from(holder.querySelectorAll('.c-hero__chiptext')).map((text) => Math.ceil(text.getBoundingClientRect().width) + CHIP_CHROME);
        if (!widths.length) {
            return;
        }
        const inARow = widths.reduce((sum, width) => sum + width, 0) + CHIP_GAP * (widths.length - 1);
        // "pairs" is the wrapped layout: each suggestion at its own width, on as many rows as they need.
        const layout = inARow <= room ? 'row' : Math.max(...widths) <= room ? 'pairs' : 'stack';
        if (layout !== this.chipLayout) {
            this.chipLayout = layout;
        }
    }

    async load() {
        try {
            this.home = await getHome();
            this.failure = undefined;
        } catch (error) {
            this.failure = error?.body?.message ?? 'We could not load your account. Please refresh the page.';
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------------------------- the router

    /** The address bar holds the page as "#/policy/<id>", so Back works and a page can be linked to. */
    readHash() {
        const [, page, recordId] = (window.location.hash || '').split('/');
        if (page && PAGES[page] && (page !== this.route.page || recordId !== this.route.recordId)) {
            this.show(page, recordId);
        } else if (!page && this.route.page !== 'home') {
            this.show('home');
        }
    }

    /**
     * Goes to a page by name. "ask" opens the conversation rather than a page.
     * @param {string} page One of the names in PAGES, or "ask"
     * @param {string} [recordId] The policy, claim or request for the pages that show one; for a form, the policy to start it on
     * @returns {Promise<boolean>} Whether the page was shown
     */
    async go(page, recordId) {
        if (page === 'ask') {
            this.isChatOpen = true;
            return true;
        }
        if (!PAGES[page]) {
            return false;
        }
        // A quote needs to know what it is for. Without that, offer the choices.
        if (page === 'newQuote' && !recordId) {
            return this.go('quotes');
        }
        const hash = `#/${page}${recordId ? `/${recordId}` : ''}`;
        if (window.location.hash !== hash) {
            window.history.pushState(null, '', hash);
        }
        return this.show(page, recordId);
    }

    async show(page, recordId) {
        this.notFound = false;
        this.formState = undefined;
        this.pointedSection = undefined;
        if (PAGES[page].record) {
            try {
                // The server returns the record only if it is this customer's.
                if (page === 'policy') {
                    this.policy = await getPolicy({ policyId: recordId });
                } else if (page === 'claim') {
                    this.claim = await getClaim({ claimId: recordId });
                } else if (page === 'request') {
                    this.request = await getRequest({ requestId: recordId });
                } else {
                    // A quote's own component reads it, and the server checks it is theirs there.
                    this.quoteSeen = undefined;
                }
            } catch (error) {
                this.route = { page };
                this.notFound = true;
                this.nameTab();
                return false;
            }
        }
        this.route = { page, recordId };
        this.nameTab();
        const scroller = this.template.querySelector('.c-scroll');
        if (scroller) {
            scroller.scrollTop = 0;
        }
        if (PAGES[page].form) {
            // Let the form draw, then read it so Claude knows what is on screen.
            await this.nextFrame();
            this.readForm();
        }
        return true;
    }

    /** The browser tab says which page this is and whose site: "Policies | Antsurance". */
    nameTab() {
        const page = this.notFound ? 'Not found' : this.route.page === 'home' ? 'Home' : this.pageTitle;
        document.title = `${page} | Antsurance`;
    }

    nextFrame() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((resolve) => setTimeout(resolve, 60));
    }

    /** The form on screen: one of the portal's forms, or a quote being answered, which takes the same calls. */
    get form() {
        return this.template.querySelector('c-antsurance-portal-form') ?? this.template.querySelector('c-antsurance-portal-quote.c-answering');
    }

    get chat() {
        return this.template.querySelector('c-antsurance-portal-chat');
    }

    readForm() {
        this.formState = this.form?.describe();
    }

    // ------------------------------------------------------------------------------- what Claude sees

    /** The page as Claude should understand it. Sent with every message. */
    get screen() {
        const page = this.route.page;
        const screen = { page, title: this.pageTitle };
        if (page === 'policy' && this.policy) {
            screen.record = { kind: 'policy', id: this.policy.id, label: `${this.policy.line} policy ${this.policy.policyNumber}` };
            screen.sections = ['coverages', 'people', 'items', 'extras', 'documents', 'bill'];
        } else if (page === 'claim' && this.claim) {
            screen.record = { kind: 'claim', id: this.claim.id, label: `Claim ${this.claim.claimNumber}: ${this.claim.title}` };
        } else if (page === 'request' && this.request) {
            screen.record = { kind: 'request', id: this.request.id, label: `Request ${this.request.requestNumber}: ${this.request.title}` };
        } else if (page === 'quote' && this.quoteSeen) {
            screen.record = { kind: 'quote', id: this.quoteSeen.id, label: this.quoteSeen.label };
        } else if (page === 'home') {
            screen.sections = ['policies', 'claims', 'requests'];
        }
        if (this.formState) {
            screen.form = this.formState;
        }
        return screen;
    }

    // ------------------------------------------------------------------------------- the action channel

    /** Carries out what Claude asked for, in order, and tells the conversation what happened. */
    async handleActions(event) {
        const actions = event.detail.actions;
        // What Claude is told happened, and what the customer is shown: one short line for each thing done.
        const results = [];
        const receipt = [];
        for (let index = 0; index < actions.length; index += 1) {
            const action = actions[index];
            this.announce(action.say);
            if (action.type === 'navigate') {
                // eslint-disable-next-line no-await-in-loop
                const opened = await this.go(action.page, action.recordId ?? action.target);
                results.push(opened ? `Opened the page "${action.page === 'ask' ? 'conversation' : this.pageTitle}"` : `Could not open ${action.page}`);
                // Opening a form only to fill it is one thing to the customer, said by the fill.
                const next = actions[index + 1];
                if (opened && !(next?.type === 'fill' && next.page === action.page)) {
                    receipt.push({ text: `Took you to ${this.placeName(action.page)}` });
                }
            } else if (action.type === 'fill') {
                if (this.route.page !== action.page) {
                    // eslint-disable-next-line no-await-in-loop
                    await this.go(action.page);
                }
                // A quote's questions arrive a moment after its page opens.
                // eslint-disable-next-line no-await-in-loop
                await this.form?.whenReady?.();
                const labels = this.form?.fill(action.fields) ?? [];
                this.readForm();
                results.push(labels.length ? `Filled in on the "${this.pageTitle}" form: ${labels.join(', ')}` : 'Nothing could be filled in');
                if (labels.length) {
                    const needed = (this.formState?.fields ?? []).filter((field) => !field.value && (field.required || field.wanted)).map((field) => ({ name: field.name, label: field.label }));
                    receipt.push({ text: `Filled in ${labels.length === 1 ? '1 field' : `${labels.length} fields`}`, where: `On the ${this.pageTitle} form`, fields: labels, needed, page: action.page });
                }
            } else if (action.type === 'highlight' || action.type === 'point') {
                if (action.page && PAGES[action.page] && this.route.page !== action.page) {
                    // eslint-disable-next-line no-await-in-loop
                    await this.go(action.page);
                }
                const label = this.form?.highlight(action.target) ?? this.pointAt(action.target);
                results.push(label ? `Pointed at ${label}` : `Could not find "${action.target}" on this page`);
                // A fill's receipt already lists what is still needed, which is the pointing; do not stack a second line.
                if (label && action.type === 'highlight' && !receipt.some((line) => line.fields)) {
                    receipt.push({ text: `Pointed out ${label}` });
                }
            }
        }
        // A customer pressing "Still needed" is their own doing, not Claude's, so it leaves no receipt.
        if (results.length && !event.detail.quiet) {
            this.chat?.note(`${results.join('. ')}.`, receipt.length ? receipt : undefined);
        }
    }

    /** A page in the customer's words, for "Took you to ...". */
    placeName(page) {
        if (page === 'policy' && this.policy) {
            return `your ${this.policy.line.toLowerCase()} policy`;
        }
        if (page === 'claim' && this.claim) {
            return `claim ${this.claim.claimNumber}`;
        }
        if (page === 'request' && this.request) {
            return `request ${this.request.requestNumber}`;
        }
        return (
            {
                home: 'the home page',
                policies: 'your policies',
                claims: 'your claims',
                requests: 'your requests',
                addDriver: 'the Add a driver form',
                newRequest: 'the request form',
                newClaim: 'the claim form',
                quotes: 'the quotes you can ask for',
                newQuote: 'your quote',
                quote: 'your quote',
                ask: 'the conversation'
            }[page] ?? 'that page'
        );
    }

    /** Points at a section of the page by name. On the policy page the section belongs to the policy component. */
    pointAt(name) {
        const labels = {
            coverages: 'what you are covered for',
            people: 'who is on it',
            items: 'what is insured',
            extras: 'the changes to this policy',
            documents: 'your documents',
            bill: 'your bill',
            policies: 'your policies',
            claims: 'your open claims',
            requests: 'your requests'
        };
        if (!labels[name]) {
            return undefined;
        }
        this.pointedSection = name;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.template.querySelector(`[data-section="${name}"]`)?.scrollIntoView({ block: 'center' });
        }, 50);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (this.pointedSection === name) {
                this.pointedSection = undefined;
            }
        }, 6000);
        return labels[name];
    }

    /** Says what Claude is doing, at the top of the page, for a few seconds. */
    announce(text) {
        if (!text) {
            return;
        }
        this.announcement = text;
        clearTimeout(this.announceTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.announceTimer = setTimeout(() => {
            this.announcement = undefined;
        }, 6000);
    }

    // ------------------------------------------------------------------------------- events

    handleNav(event) {
        this.go(event.currentTarget.dataset.page, event.currentTarget.dataset.record);
    }

    /** A card, a page or a form asked to go somewhere. */
    handleOpen(event) {
        event.stopPropagation();
        this.go(event.detail.page, event.detail.recordId);
    }

    /** A page asked Claude a question for the customer. */
    handleAskEvent(event) {
        this.askClaude(event.detail.text);
    }

    handleFormChange() {
        this.readForm();
    }

    /** The customer sent a form. Refresh what the pages show and let the conversation know. */
    handleSent(event) {
        const { form, receipt } = event.detail;
        this.readForm();
        this.load();
        this.chat?.note(`The customer sent the "${PAGES[form].title}" form${receipt.referenceNumber ? `. Reference ${receipt.referenceNumber}` : ''}.`, [
            { text: receipt.referenceNumber ? `You sent it. Reference ${receipt.referenceNumber}` : 'You sent it' }
        ]);
    }

    /** A note or a withdrawal is filed a moment after it is sent, so read the request again shortly. */
    handleRequestChanged() {
        const requestId = this.request?.id;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(async () => {
            if (this.route.page === 'request' && this.request?.id === requestId) {
                try {
                    this.request = await getRequest({ requestId });
                } catch (error) {
                    // Leave the page as it is; the next visit reads it again.
                }
            }
            this.load();
        }, 3500);
    }

    handlePrompt(event) {
        this.prompt = event.target.value;
    }

    handlePromptKey(event) {
        if (event.key === 'Enter') {
            this.handleAsk();
        }
    }

    handleAsk() {
        const text = this.prompt.trim();
        if (text) {
            this.askClaude(text);
            this.prompt = '';
            const input = this.template.querySelector('.c-ask__input');
            if (input) {
                input.value = '';
            }
        } else {
            this.isChatOpen = true;
        }
    }

    handleSuggestion(event) {
        this.askClaude(event.currentTarget.dataset.text);
    }

    handleFillWithClaude() {
        this.askClaude(`Help me fill in the ${PAGES[this.route.page].title.toLowerCase()} form.`);
    }

    /** A quote that was sent has loaded: Claude can now be told which one is on screen. */
    handleQuoteLoaded(event) {
        this.quoteSeen = event.detail;
    }

    handleAskClaim() {
        this.askClaude(`Where does my claim "${this.claim.title}" stand, and what happens next?`);
    }

    askClaude(text) {
        this.isChatOpen = true;
        this.chat?.ask(text);
    }

    handleToggleChat() {
        this.isChatOpen = !this.isChatOpen;
    }

    handleCloseChat() {
        this.isChatOpen = false;
        this.isChatWide = false;
    }

    handleWiden() {
        this.isChatWide = !this.isChatWide;
    }

    /** The conversation gained or lost its messages. */
    handleTalk(event) {
        this.hasConversation = event.detail.count > 0;
    }

    /** Starts the conversation over. The page stays as it is: a form keeps everything in it. */
    handleNewChat() {
        this.chat?.reset();
    }

    // ------------------------------------------------------------------------------- what the template reads

    get isReady() {
        return Boolean(this.home);
    }

    get pageTitle() {
        const page = this.route.page;
        if (page === 'policy' && this.policy) {
            return `${this.policy.line} policy`;
        }
        if (page === 'claim' && this.claim) {
            return `Claim ${this.claim.claimNumber}`;
        }
        if (page === 'request' && this.request) {
            return `Request ${this.request.requestNumber}`;
        }
        return PAGES[page].title;
    }

    get nav() {
        const current = PAGES[this.route.page].nav;
        return NAV.map((item) => ({ ...item, className: item.page === current ? 'c-nav__item c-nav__item_current' : 'c-nav__item', current: item.page === current ? 'page' : undefined }));
    }

    get isHome() {
        return this.route.page === 'home' && !this.notFound;
    }
    get isPolicies() {
        return this.route.page === 'policies';
    }
    get isPolicy() {
        return this.route.page === 'policy' && !this.notFound && Boolean(this.policy);
    }
    get isClaims() {
        return this.route.page === 'claims';
    }
    get isClaim() {
        return this.route.page === 'claim' && !this.notFound && Boolean(this.claim);
    }
    get isRequests() {
        return this.route.page === 'requests';
    }
    get isRequest() {
        return this.route.page === 'request' && !this.notFound && Boolean(this.request);
    }
    get isForm() {
        return Boolean(PAGES[this.route.page].form) && !PAGES[this.route.page].own;
    }
    get isQuotes() {
        return this.route.page === 'quotes';
    }
    get isNewQuote() {
        return this.route.page === 'newQuote';
    }
    get isQuote() {
        return this.route.page === 'quote' && !this.notFound;
    }

    /** Quotes still open, for Home: the two most recent. */
    get openQuotes() {
        return (this.home.quotes ?? [])
            .filter((quote) => quote.isOpen)
            .slice(0, 2)
            .map((quote) => ({
                ...quote,
                sub: `Quote ${quote.quoteNumber}, sent ${(quote.sentText ?? '').replace(/ /g, '\u00A0')}`,
                label: `Open quote ${quote.quoteNumber}`
            }));
    }

    get hasOpenQuotes() {
        return this.openQuotes.length > 0;
    }

    get greeting() {
        const hour = new Date().getHours();
        const part = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
        return `${part}, ${this.home.firstName}`;
    }

    get activePolicies() {
        return this.home.policies.filter((policy) => policy.inForce);
    }

    get pastPolicies() {
        return this.home.policies.filter((policy) => !policy.inForce);
    }

    get hasPastPolicies() {
        return this.pastPolicies.length > 0;
    }

    /** Home shows the three most recent open claims; the rest are one press away on the claims page. */
    get openClaims() {
        return this.home.claims.filter((claim) => claim.isOpen).slice(0, 3);
    }

    get hasOpenClaims() {
        return this.openClaims.length > 0;
    }

    get hasClaims() {
        return this.home.claims.length > 0;
    }

    get requests() {
        return this.home.requests.map((request) => ({
            ...request,
            chipClass: request.isOpen ? 'c-chip c-chip_clay' : 'c-chip',
            title: keepLastWordsTogether(request.title, true),
            // The date stays in one piece.
            sub: `Request ${request.requestNumber}, sent ${(request.openedText ?? '').replace(/ /g, '\u00A0')}`,
            label: `Open request ${request.requestNumber}: ${request.title}`
        }));
    }

    /** Home shows up to five requests in progress; the rest are on the requests page. */
    get openRequests() {
        return this.requests.filter((request) => request.isOpen).slice(0, PAGE_SIZE);
    }

    // ------------------------------------------------------------------------------- lists in pages

    /**
     * One page of a list, with what the pager needs to say how much is behind it.
     * @param {object[]} list Every row
     * @param {number} page The page asked for, from zero
     * @returns {{rows: object[], count: number, show: boolean, label: string, prevDisabled: boolean, nextDisabled: boolean}}
     */
    paged(list, page) {
        const pages = Math.max(1, Math.ceil(list.length / PAGE_SIZE));
        const current = Math.min(Math.max(page, 0), pages - 1);
        const start = current * PAGE_SIZE;
        const rows = list.slice(start, start + PAGE_SIZE);
        return {
            rows,
            count: list.length,
            show: list.length > PAGE_SIZE,
            label: `${start + 1} to ${start + rows.length} of ${list.length}`,
            prevDisabled: current === 0,
            nextDisabled: current >= pages - 1
        };
    }

    get claimList() {
        return this.paged(this.home.claims, this.claimPage);
    }

    get requestList() {
        return this.paged(this.requests, this.requestPage);
    }

    handlePage(event) {
        const { list, step } = event.currentTarget.dataset;
        if (list === 'claims') {
            this.claimPage = Math.max(0, this.claimPage + Number(step));
        } else {
            this.requestPage = Math.max(0, this.requestPage + Number(step));
        }
    }

    get hasOpenRequests() {
        return this.openRequests.length > 0;
    }

    get hasRequests() {
        return this.home.requests.length > 0;
    }

    get hasAuto() {
        return this.activePolicies.some((policy) => (policy.line ?? '').includes('Auto'));
    }

    get homeSection() {
        const pointed = (name) => (this.pointedSection === name ? 'c-section c-section_pointed' : 'c-section');
        return { policies: pointed('policies'), claims: pointed('claims'), requests: pointed('requests') };
    }

    /** What happens after the form on screen is sent, and the policy it starts on. */
    get support() {
        const steps = (NEXT_STEPS[this.route.page] ?? []).map((text, index) => ({ key: `${index}`, number: index + 1, text: keepLastWordsTogether(text, true) }));
        const policy = this.home.policies.find((entry) => entry.id === this.route.recordId);
        return { steps, policy, hasPolicy: Boolean(policy) };
    }

    get claimSteps() {
        return ['Make sure everyone is safe. Call 911 if anyone is hurt.', 'File a claim here, or tell Claude what happened.', 'An adjuster contacts you within one business day.'].map((text, index) => ({
            key: `${index}`,
            number: index + 1,
            text: keepLastWordsTogether(text, true)
        }));
    }

    get changeNote() {
        return keepLastWordsTogether('Ask for it here and a person on our service team will pick it up, usually within one business day.', true);
    }

    get claimPolicy() {
        return this.home.policies.find((entry) => entry.id === this.claim?.policyId);
    }

    get siteClass() {
        return 'c-site' + (this.isChatOpen ? ' c-site_chat' : '') + (this.isChatOpen && this.isChatWide ? ' c-site_chat-wide' : '');
    }

    /** Every page starts the same distance under the header, so a heading is always where the last one was. */
    get mainClass() {
        return 'c-main';
    }

    /** Home already shows the suggestions beside its own prompt, so the conversation does not repeat them there. */
    get chatStarters() {
        return this.isHome ? [] : this.home.suggestions;
    }

    get chipsClass() {
        return `c-hero__chips c-hero__chips_${this.chipLayout}`;
    }

    get dockClass() {
        return this.isChatOpen ? 'c-dock c-dock_open' : 'c-dock';
    }

    get launcherClass() {
        return this.isChatOpen ? 'c-launcher c-launcher_hidden' : 'c-launcher';
    }

    get widenLabel() {
        return this.isChatWide ? 'Make the conversation narrower' : 'Make the conversation wider';
    }

    get widenIcon() {
        return this.isChatWide ? 'utility:contract_alt' : 'utility:expand_alt';
    }

    get chatExpanded() {
        return this.isChatOpen ? 'true' : 'false';
    }

    get signOutUrl() {
        return `${basePath}vforcesite/secur/logout.jsp`;
    }
}
