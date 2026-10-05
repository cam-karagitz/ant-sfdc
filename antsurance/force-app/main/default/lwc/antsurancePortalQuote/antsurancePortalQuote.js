import { LightningElement, api, track } from 'lwc';
import getOffers from '@salesforce/apex/AntsurancePortalQuote.getOffers';
import start from '@salesforce/apex/AntsurancePortalQuote.start';
import priceAnswers from '@salesforce/apex/AntsurancePortalQuote.price';
import explainQuestion from '@salesforce/apex/AntsurancePortalQuote.explain';
import sendQuote from '@salesforce/apex/AntsurancePortalQuote.send';
import getSent from '@salesforce/apex/AntsurancePortalQuote.getSent';
import findReceipt from '@salesforce/apex/AntsurancePortalController.findReceipt';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import { keepLastWordsTogether } from 'c/antsurancePortalText';

const LINE_ICONS = { renters: 'utility:home', auto: 'utility:travel_and_places', home: 'utility:home', umbrella: 'utility:shield' };
const REVIEW = 'review';
/** At most this many questions are on screen at once: five where the quote has the page's full width, three beside the
 * conversation or on a phone, where each question takes more lines. A longer step is walked in parts. */
const PER_PART_WIDE = 5;
const PER_PART_NARROW = 3;
const FULL_WIDTH = 900;
/** Typed answers a quote can be sent without. Every other typed answer is asked for before sending. */
const OPTIONAL = ['priorCarrier'];

/**
 * A quote a customer builds for themselves. With no `slug` it offers the lines they can ask about; with one it
 * walks the line's questions a step at a time beside a price that follows every answer; with a `quoteId` it
 * shows a quote already sent. The questions and the price come from the same rating code the agents use.
 *
 * Claude helps in two ways. In place: "What does this mean?" under any question asks Claude to explain it for
 * this customer, and may offer an answer their own records point to. From the conversation: this component has
 * the same `fill`, `highlight` and `describe` methods as the portal's forms, so Claude can answer questions for
 * the customer as they talk, each one marked until the customer changes it. Nothing is sent until they press Send.
 */
export default class AntsurancePortalQuote extends LightningElement {
    /** Quotes the customer has already sent, for the page that offers a new one. */
    @api quotes = [];

    @track offers = [];
    @track form;
    @track answers = {};
    @track fromRecords = [];
    @track byClaude = [];
    @track explained = {};
    @track price;
    @track receipt;
    @track sent;
    @track blanks = [];
    /** The review sections left open. The first starts open. */
    @track openFolds;
    stepIndex = 0;
    part = 0;
    isLoading = false;
    isPricing = false;
    isSending = false;
    failure;
    loadFailure;
    highlighted;
    delta;
    lineSlug;
    sentId;
    ready = Promise.resolve();
    priceTimer;
    priceRun = 0;
    spark = SPARK;
    room = 'wide';
    isFull = true;
    watcher;
    watching = false;
    onResize;

    connectedCallback() {
        if (!this.lineSlug && !this.sentId) {
            this.loadOffers();
        }
    }

    /**
     * Measures the room the quote has, so the price sits beside the questions only where there is room for both.
     * A tab that is not in front draws no frames, so the observer alone is not enough: the width is also read on
     * every draw and whenever the window changes size.
     */
    renderedCallback() {
        this.measure();
        if (this.watching) {
            return;
        }
        this.watching = true;
        this.onResize = () => this.measure();
        window.addEventListener('resize', this.onResize);
        if (typeof ResizeObserver !== 'undefined') {
            this.watcher = new ResizeObserver(() => this.measure());
            this.watcher.observe(this.template.host);
        }
        // A tab that is not in front draws no frames, so the observer above stays silent there, and opening the
        // conversation narrows the page without a resize event. A slow timer catches both.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.ticker = setInterval(() => this.measure(), 1500);
    }

    measure() {
        // The laid-out width, which page zoom leaves alone; a bounding box is scaled by it.
        const width = this.template.host.offsetWidth || this.template.host.getBoundingClientRect().width;
        const isFull = width === 0 || width >= FULL_WIDTH;
        if (isFull !== this.isFull) {
            // The parts change size, so stay on the part that holds the first question now on screen.
            const first = this.part * this.perPart;
            this.isFull = isFull;
            this.part = Math.floor(first / this.perPart);
        }
        const room = width === 0 || width >= 752 ? 'wide' : width >= 480 ? 'medium' : 'small';
        if (room !== this.room) {
            this.room = room;
        }
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.onResize);
        clearInterval(this.ticker);
        this.watcher?.disconnect();
        this.watcher = undefined;
        this.watching = false;
        clearTimeout(this.priceTimer);
    }

    get perPart() {
        return this.isFull ? PER_PART_WIDE : PER_PART_NARROW;
    }

    get quoteClass() {
        return this.room === 'wide' ? 'c-quote' : `c-quote c-quote_${this.room}`;
    }

    /** The line to quote: renters, auto, home or umbrella. */
    @api
    get slug() {
        return this.lineSlug;
    }
    set slug(value) {
        if (value && value !== this.lineSlug) {
            this.lineSlug = value;
            this.ready = this.loadForm(value);
        }
    }

    /** A quote already sent, to show as it stands. */
    @api
    get quoteId() {
        return this.sentId;
    }
    set quoteId(value) {
        if (value && value !== this.sentId) {
            this.sentId = value;
            this.ready = this.loadSent(value);
        }
    }

    async loadOffers() {
        this.isLoading = true;
        try {
            this.offers = await getOffers();
        } catch (error) {
            this.loadFailure = error?.body?.message ?? 'We could not load this page. Please refresh it.';
        } finally {
            this.isLoading = false;
        }
    }

    async loadForm(slug) {
        this.isLoading = true;
        this.loadFailure = undefined;
        this.receipt = undefined;
        this.sent = undefined;
        try {
            const form = await start({ slug });
            this.form = form;
            this.answers = JSON.parse(form.answersJson);
            this.fromRecords = [...(form.fromRecords ?? [])];
            this.byClaude = [];
            this.explained = {};
            this.blanks = [];
            this.price = form.price;
            this.stepIndex = 0;
            this.part = 0;
            this.delta = undefined;
        } catch (error) {
            this.loadFailure = error?.body?.message ?? 'We could not start that quote. Please try again.';
        } finally {
            this.isLoading = false;
            this.announceChange();
        }
    }

    async loadSent(quoteId) {
        this.isLoading = true;
        this.loadFailure = undefined;
        try {
            const sent = await getSent({ quoteId });
            this.sent = sent;
            this.form = sent;
            this.answers = JSON.parse(sent.answersJson);
            this.price = sent.price;
            this.dispatchEvent(new CustomEvent('loaded', { detail: { id: sent.id, label: `Quote ${sent.quoteNumber}: ${sent.title}` } }));
        } catch (error) {
            this.loadFailure = error?.body?.message ?? 'We could not find that on your account.';
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------------------------- which view

    get isChoosing() {
        return !this.lineSlug && !this.sentId && !this.isLoading && !this.loadFailure;
    }

    get isAnswering() {
        return Boolean(this.lineSlug && this.form && !this.receipt && !this.loadFailure);
    }

    get isSentView() {
        return Boolean(this.sentId && this.sent && !this.loadFailure);
    }

    get isReceipt() {
        return Boolean(this.receipt);
    }

    // ------------------------------------------------------------------------------- the page that offers quotes

    get offerRows() {
        return this.offers.map((offer) => ({
            ...offer,
            icon: LINE_ICONS[offer.slug] ?? 'utility:shield',
            label: `Start a quote for ${offer.title.toLowerCase()}`,
            blurb: keepLastWordsTogether(offer.blurb, true)
        }));
    }

    get sentRows() {
        return (this.quotes ?? []).map((quote) => ({
            ...quote,
            sub: `Quote ${quote.quoteNumber}, sent ${(quote.sentText ?? '').replace(/ /g, ' ')}`,
            chipClass: quote.isOpen ? 'c-chip c-chip_clay' : 'c-chip',
            label: `Open quote ${quote.quoteNumber}`
        }));
    }

    get hasSentRows() {
        return this.sentRows.length > 0;
    }

    handleOffer(event) {
        this.open('newQuote', event.currentTarget.dataset.slug);
    }

    handleSentRow(event) {
        this.open('quote', event.currentTarget.dataset.id);
    }

    handleAskWhich() {
        this.dispatchEvent(new CustomEvent('ask', { detail: { text: 'Which other insurance might my household need, given what I already have?' } }));
    }

    open(page, recordId) {
        this.dispatchEvent(new CustomEvent('open', { detail: { page, recordId }, bubbles: true, composed: true }));
    }

    // ------------------------------------------------------------------------------- the questions

    /** The questions asked under the answers so far, by step. A question that depends on another answer comes and goes with it. */
    get asked() {
        return (this.form?.steps ?? []).map((step) => ({
            ...step,
            asks: step.asks.filter((ask) => !ask.showWhenKey || (ask.showWhenValues ?? []).includes(String(this.answers[ask.showWhenKey] ?? '')))
        }));
    }

    get stepCount() {
        return this.asked.length;
    }

    get isReview() {
        return this.stepIndex >= this.stepCount;
    }

    get stepsBar() {
        const steps = this.asked.map((step, index) => ({ key: step.key, label: step.title, index }));
        steps.push({ key: REVIEW, label: 'Review and send', index: steps.length });
        return steps.map((step) => ({
            ...step,
            number: step.index + 1,
            selected: step.index === this.stepIndex ? 'true' : 'false',
            // A step is done once it has been passed with every needed answer in.
            className: 'c-steps__tab' + (step.index === this.stepIndex ? ' c-steps__tab_selected' : '') + (step.index < this.stepIndex && !this.stepIsMissing(step.index) ? ' c-steps__tab_done' : '')
        }));
    }

    /** The needed answers that are still blank, across every step. */
    get missingNow() {
        const missing = [];
        this.asked.forEach((step) =>
            step.asks.forEach((ask) => {
                if ((ask.choices ?? []).length === 0 && !OPTIONAL.includes(ask.key) && !String(this.answers[ask.key] ?? '').trim()) {
                    missing.push(ask.key);
                }
            })
        );
        return missing;
    }

    stepIsMissing(index) {
        const missing = this.missingNow;
        return (this.asked[index]?.asks ?? []).some((ask) => missing.includes(ask.key));
    }

    /** The quote can be sent once nothing needed is blank. Until then the review lists what is missing. */
    get sendDisabled() {
        return this.isSending || this.missingNow.length > 0;
    }

    get step() {
        return this.asked[this.stepIndex];
    }

    get stepIntro() {
        return keepLastWordsTogether(this.step?.intro, true);
    }

    get progress() {
        return `Step ${Math.min(this.stepIndex + 1, this.stepCount + 1)} of ${this.stepCount + 1}`;
    }

    /** How many parts the step on screen is walked in. */
    get parts() {
        return Math.max(1, Math.ceil((this.step?.asks ?? []).length / this.perPart));
    }

    get hasParts() {
        return this.parts > 1 && !this.isReview;
    }

    /** How much of a long step is on screen: "Questions 1 to 5 of 11". */
    get partLabel() {
        const total = (this.step?.asks ?? []).length;
        const first = this.part * this.perPart + 1;
        return `Questions ${first} to ${Math.min(first + this.perPart - 1, total)} of ${total}`;
    }

    get questions() {
        return (this.step?.asks ?? []).slice(this.part * this.perPart, (this.part + 1) * this.perPart).map((ask) => this.view(ask));
    }

    view(ask) {
        const value = this.answers[ask.key] ?? '';
        const isChoice = ask.type === 'choice' || ask.type === 'toggle';
        const explained = this.explained[ask.key];
        const mark = this.byClaude.includes(ask.key) ? 'Filled in by Claude. Change it if it is not right.' : this.fromRecords.includes(ask.key) ? 'From your account. Change it if it is not right.' : '';
        // A customer who already has another policy here is told so, rather than asked whether they would like one.
        const alreadyBundled = ask.key === 'bundle' && this.fromRecords.includes('bundle') && String(value) === 'true';
        return {
            key: ask.key,
            eyebrow: ask.label,
            ask: alreadyBundled ? 'You already have another policy with us, so the discount for more than one applies.' : ask.ask,
            inputId: `q-${ask.key}`,
            isChoice,
            isNumber: ask.type === 'number',
            isCurrency: ask.type === 'currency',
            isText: ask.type === 'text',
            // An amount reads as the price card writes it: 20,000, not 20000.
            value: ask.type === 'currency' && value !== '' && !Number.isNaN(Number(value)) ? Number(value).toLocaleString('en-US') : value,
            options: (ask.choices ?? []).map((choice) => ({
                key: `${ask.key}-${choice.value}`,
                value: choice.value,
                label: choice.label,
                effect: choice.effect,
                checked: String(value) === choice.value ? 'true' : 'false',
                className: 'c-pick' + (String(value) === choice.value ? ' c-pick_chosen' : '')
            })),
            mark,
            markClass: this.byClaude.includes(ask.key) ? 'c-ask__mark c-ask__mark_claude' : 'c-ask__mark',
            isBlank: this.blanks.includes(ask.key),
            className:
                'c-ask' +
                (this.byClaude.includes(ask.key) ? ' c-ask_claude' : '') +
                (this.highlighted === ask.key ? ' c-ask_pointed' : '') +
                (this.blanks.includes(ask.key) ? ' c-ask_blank' : ''),
            // One small "?" beside each question, not the same sentence five times down the page.
            explainLabel: explained ? 'Hide' : '?',
            explainAria: explained ? `Hide the explanation of: ${ask.label}` : `What does this mean: ${ask.label}`,
            explainClass: explained ? 'c-link c-ask__why' : 'c-ask__help',
            explainOpen: explained ? 'true' : 'false',
            explained: explained
                ? {
                      ...explained,
                      text: keepLastWordsTogether(explained.text, true),
                      hasSuggestion: Boolean(explained.suggestValue) && String(value) !== explained.suggestValue,
                      useLabel: `Use ${explained.suggestLabel}`
                  }
                : undefined
        };
    }

    handlePick(event) {
        const { key, value } = event.currentTarget.dataset;
        this.setAnswer(key, value);
    }

    handleType(event) {
        const key = event.target.dataset.key;
        const kind = event.target.dataset.kind;
        const typed = event.target.value;
        this.setAnswer(key, kind === 'text' ? typed : typed.replace(/[^0-9]/g, ''));
    }

    /** The customer answered. The answer is theirs from here on, and the price follows it. */
    setAnswer(key, value) {
        this.answers = { ...this.answers, [key]: value };
        this.byClaude = this.byClaude.filter((entry) => entry !== key);
        this.fromRecords = this.fromRecords.filter((entry) => entry !== key);
        this.blanks = this.blanks.filter((entry) => entry !== key);
        this.forget(key);
        this.reprice();
        this.announceChange();
    }

    /** What Claude said about a question was about the answer it had then. A new answer clears it. */
    forget(key) {
        if (this.explained[key] && !this.explained[key].isLoading) {
            const explained = { ...this.explained };
            delete explained[key];
            this.explained = explained;
        }
    }

    /** Asks for the price a moment after the last change, so typing an amount is one request. */
    reprice() {
        clearTimeout(this.priceTimer);
        this.isPricing = true;
        this.priceRun += 1;
        const run = this.priceRun;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.priceTimer = setTimeout(async () => {
            const before = this.price?.premium;
            try {
                const price = await priceAnswers({ slug: this.lineSlug, answersJson: JSON.stringify(this.answers) });
                if (run !== this.priceRun) {
                    return;
                }
                this.price = price;
                const change = before === undefined ? 0 : Math.round(price.premium - before);
                this.delta = change === 0 ? undefined : `${change > 0 ? 'Up' : 'Down'} $${Math.abs(change).toLocaleString('en-US')} a year from your last answer`;
                this.announceChange();
            } catch (error) {
                // The price shown stays as it was; the next answer tries again.
            } finally {
                if (run === this.priceRun) {
                    this.isPricing = false;
                }
            }
        }, 350);
    }

    handleStep(event) {
        this.goToStep(Number(event.currentTarget.dataset.index));
    }

    handleStepKey(event) {
        const last = this.stepCount;
        const to = { ArrowRight: Math.min(this.stepIndex + 1, last), ArrowLeft: Math.max(this.stepIndex - 1, 0), Home: 0, End: last }[event.key];
        if (to === undefined) {
            return;
        }
        event.preventDefault();
        this.goToStep(to);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(`.c-steps__tab[data-index="${to}"]`)?.focus(), 30);
    }

    /** Next and Back walk the parts of a long step before moving to the step beside it. */
    handleNext() {
        if (!this.isReview && this.part < this.parts - 1) {
            this.goToStep(this.stepIndex, this.part + 1);
        } else {
            this.goToStep(this.stepIndex + 1);
        }
    }

    handleBack() {
        if (!this.isReview && this.part > 0) {
            this.goToStep(this.stepIndex, this.part - 1);
        } else {
            const before = this.stepIndex - 1;
            const asks = this.asked[before]?.asks ?? [];
            this.goToStep(before, Math.max(0, Math.ceil(asks.length / this.perPart) - 1));
        }
    }

    goToStep(index, part = 0) {
        this.stepIndex = Math.max(0, Math.min(index, this.stepCount));
        this.part = part;
        this.failure = undefined;
        if (this.isReview) {
            // The review says what is still needed before it offers to send.
            this.blanks = this.missingNow;
        }
        this.announceChange();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector('.c-quote__main')?.scrollIntoView({ block: 'nearest' }), 30);
    }

    get nextLabel() {
        return this.stepIndex === this.stepCount - 1 && this.part >= this.parts - 1 ? 'Review' : 'Next';
    }

    get backDisabled() {
        return this.stepIndex === 0 && this.part === 0;
    }

    // ------------------------------------------------------------------------------- Claude, in place

    async handleExplain(event) {
        const key = event.currentTarget.dataset.key;
        if (this.explained[key]) {
            const explained = { ...this.explained };
            delete explained[key];
            this.explained = explained;
            return;
        }
        this.explained = { ...this.explained, [key]: { isLoading: true } };
        try {
            const answer = await explainQuestion({ slug: this.lineSlug, key, answersJson: JSON.stringify(this.answers) });
            if (this.explained[key]) {
                this.explained = { ...this.explained, [key]: { ...answer, isLoading: false } };
            }
        } catch (error) {
            this.explained = { ...this.explained, [key]: { failed: true, text: 'Claude could not explain this one just then. Try again, or ask in the conversation.' } };
        }
    }

    handleUse(event) {
        const { key, value } = event.currentTarget.dataset;
        this.setAnswer(key, value);
    }

    handleAskMore(event) {
        const ask = this.find(event.currentTarget.dataset.key);
        this.dispatchEvent(new CustomEvent('ask', { detail: { text: `On my ${this.form.title.toLowerCase()} quote, help me choose for "${ask?.label}".` } }));
    }

    // ------------------------------------------------------------------------------- the price

    get priceView() {
        const price = this.price ?? {};
        return {
            ...price,
            lines: (price.lines ?? []).map((line, index) => ({ ...line, key: `${index}`, note: line.effect && !line.effect.startsWith('Added') ? line.effect : '' })),
            hasLines: (price.lines ?? []).length > 0,
            note: keepLastWordsTogether(price.note, true),
            noteClass: price.needsReview ? 'c-price__note c-price__note_watch' : 'c-price__note',
            stateClass: this.isPricing ? 'c-price__figure c-price__figure_busy' : 'c-price__figure'
        };
    }

    // ------------------------------------------------------------------------------- review and send

    /** Every answer, by step, in the customer's words. */
    get reviewGroups() {
        return this.asked.map((step, index) => ({
            key: step.key,
            title: step.title,
            index,
            count: step.asks.length,
            open: this.openFolds ? this.openFolds.includes(step.key) : index === 0,
            rows: step.asks.map((ask) => ({ key: ask.key, label: ask.label, value: this.wordsFor(ask), className: this.blanks.includes(ask.key) ? 'c-answer c-answer_blank' : 'c-answer' }))
        }));
    }

    wordsFor(ask) {
        const value = this.answers[ask.key];
        if (value === undefined || value === null || value === '') {
            return 'Not given';
        }
        const choice = (ask.choices ?? []).find((entry) => entry.value === String(value));
        if (choice) {
            return choice.label;
        }
        if (ask.type === 'currency') {
            return `$${Number(value).toLocaleString('en-US')}`;
        }
        return String(value);
    }

    /** Remembers which review sections are open, so a redraw does not close what the customer opened. */
    handleFold(event) {
        const key = event.currentTarget.dataset.key;
        const current = this.openFolds ?? [this.asked[0]?.key];
        const isOpen = event.currentTarget.open;
        if (isOpen !== current.includes(key)) {
            this.openFolds = isOpen ? [...current, key] : current.filter((entry) => entry !== key);
        }
    }

    get blankRows() {
        return this.blanks.map((key) => {
            const ask = this.find(key);
            return { key, label: ask?.label ?? key };
        });
    }

    get hasBlanks() {
        return this.blanks.length > 0;
    }

    handleBlank(event) {
        this.highlight(event.currentTarget.dataset.key);
    }

    handleEditStep(event) {
        this.goToStep(Number(event.currentTarget.dataset.index));
    }

    get sendLabel() {
        return this.isSending ? 'Sending' : 'Send for my quote';
    }

    async handleSend() {
        const blanks = this.missingNow;
        this.blanks = blanks;
        if (blanks.length) {
            this.failure = 'A few answers are still blank.';
            return;
        }
        this.isSending = true;
        this.failure = undefined;
        try {
            const sent = await sendQuote({ slug: this.lineSlug, answersJson: JSON.stringify(this.answers) });
            this.receipt = { ...sent, premiumText: this.price?.premiumText };
            const filed = await this.lookForReceipt(sent.sentAt);
            if (filed) {
                this.receipt = { ...filed, premiumText: this.price?.premiumText };
            }
            this.dispatchEvent(new CustomEvent('sent', { detail: { form: 'newQuote', receipt: filed ?? sent } }));
        } catch (error) {
            this.failure = error?.body?.message ?? 'That could not be sent. Please try again.';
        } finally {
            this.isSending = false;
        }
    }

    async lookForReceipt(sinceMillis) {
        for (let attempt = 0; attempt < 8; attempt += 1) {
            // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, 1500));
            try {
                // eslint-disable-next-line no-await-in-loop
                const filed = await findReceipt({ kind: 'quote', sinceMillis });
                if (filed) {
                    return filed;
                }
            } catch (error) {
                return undefined;
            }
        }
        return undefined;
    }

    get receiptTitle() {
        return this.receipt.referenceNumber ? `Quote ${this.receipt.referenceNumber} is with our team` : 'Your quote is sent';
    }

    get receiptNote() {
        return this.receipt.referenceNumber ? '' : 'Your quote number will show here in a moment.';
    }

    get receiptHasQuote() {
        return Boolean(this.receipt?.id);
    }

    handleSeeQuote() {
        this.open('quote', this.receipt.id);
    }

    handleHome() {
        this.open('home');
    }

    handleAnother() {
        this.open('quotes');
    }

    handleAskSent() {
        this.dispatchEvent(new CustomEvent('ask', { detail: { text: `Where does my ${this.sent.title.toLowerCase()} quote ${this.sent.quoteNumber} stand, and what happens next?` } }));
    }

    get sentChipClass() {
        return this.sent?.statusWord === 'Offer ready' ? 'c-chip c-chip_good' : 'c-chip c-chip_clay';
    }

    get lineIcon() {
        return LINE_ICONS[this.form?.slug] ?? 'utility:shield';
    }

    // ------------------------------------------------------------------------------- for Claude

    find(key) {
        for (const step of this.form?.steps ?? []) {
            const ask = step.asks.find((entry) => entry.key === key);
            if (ask) {
                return ask;
            }
        }
        return undefined;
    }

    /** Resolves once the questions have loaded, so an answer Claude gives right after opening the quote is not lost. */
    @api
    whenReady() {
        return this.ready;
    }

    /**
     * Answers questions for the customer to check. Called for Claude; each is marked until the customer changes it.
     * @param {{name: string, value: string}[]} fields The answers, by question
     * @returns {string[]} The labels of the questions that were answered
     */
    @api
    fill(fields) {
        if (!this.isAnswering) {
            return [];
        }
        const done = [];
        const answers = { ...this.answers };
        const byClaude = [...this.byClaude];
        let firstKey;
        (fields ?? []).forEach(({ name, value }) => {
            const ask = this.find(name);
            if (!ask || value === undefined || value === null || value === '') {
                return;
            }
            let next = String(value).trim();
            const choices = ask.choices ?? [];
            if (choices.length) {
                // Claude is given the values; a label, or yes and no, is taken too.
                const lower = next.toLowerCase();
                const yesNo = { yes: 'true', no: 'false' }[lower];
                const match = choices.find((choice) => choice.value === next) ?? choices.find((choice) => choice.label.toLowerCase() === lower) ?? choices.find((choice) => choice.value === yesNo);
                if (!match) {
                    return;
                }
                next = match.value;
            } else if (ask.type !== 'text') {
                next = next.replace(/[^0-9]/g, '');
                if (!next) {
                    return;
                }
            }
            answers[name] = next;
            if (!byClaude.includes(name)) {
                byClaude.push(name);
            }
            firstKey = firstKey ?? name;
            done.push(ask.label);
        });
        if (!done.length) {
            return done;
        }
        this.answers = answers;
        this.byClaude = byClaude;
        this.fromRecords = this.fromRecords.filter((entry) => !byClaude.includes(entry));
        this.blanks = this.blanks.filter((entry) => !byClaude.includes(entry));
        byClaude.forEach((key) => this.forget(key));
        this.showStepOf(firstKey);
        this.reprice();
        this.announceChange();
        return done;
    }

    /**
     * Points at a question: opens its step, scrolls it into view and outlines it for a few seconds.
     * @param {string} name The question
     * @returns {string|undefined} The question's label when this quote asks it
     */
    @api
    highlight(name) {
        const ask = this.find(name);
        if (!ask || !this.isAnswering) {
            return undefined;
        }
        this.showStepOf(name);
        this.highlighted = name;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(`[data-wrap="${name}"]`)?.scrollIntoView({ block: 'center' }), 80);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (this.highlighted === name) {
                this.highlighted = undefined;
            }
        }, 6000);
        return ask.label;
    }

    showStepOf(key) {
        const index = this.asked.findIndex((step) => step.asks.some((ask) => ask.key === key));
        if (index >= 0) {
            this.stepIndex = index;
            this.part = Math.floor(this.asked[index].asks.findIndex((ask) => ask.key === key) / this.perPart);
        }
    }

    /**
     * The quote as it stands, for Claude to read: every question asked, its answer and its choices as value=label,
     * with what each choice does to the price, and the price now.
     */
    @api
    describe() {
        if (!this.isAnswering) {
            return undefined;
        }
        const step = this.step;
        return {
            form: 'newQuote',
            title: `${this.form.title} quote`,
            line: this.form.slug,
            sent: false,
            step: this.isReview ? 'Review and send' : step?.title,
            priceNow: this.price ? `${this.price.premiumText} a year, ${this.price.monthlyText}. ${this.price.note}` : '',
            fields: this.asked.flatMap((section) =>
                section.asks.map((ask) => ({
                    name: ask.key,
                    label: ask.label,
                    value: String(this.answers[ask.key] ?? ''),
                    step: section.title,
                    help: ask.ask,
                    choices: (ask.choices ?? []).map((choice) => `${choice.value}=${choice.label}${choice.effect ? ` (${choice.effect})` : ''}`).join('; '),
                    kind: ask.type
                }))
            )
        };
    }

    announceChange() {
        this.dispatchEvent(new CustomEvent('formchange'));
    }
}
