import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import getConfiguration from '@salesforce/apex/AntsuranceQuoteConfigurator.getConfiguration';
import price from '@salesforce/apex/AntsuranceQuoteConfigurator.price';
import saveConfiguration from '@salesforce/apex/AntsuranceQuoteConfigurator.saveConfiguration';
import discardDraft from '@salesforce/apex/AntsuranceQuoteConfigurator.discardDraft';
import advise from '@salesforce/apex/AntsuranceQuoteConfigurator.advise';
import recheckAdvice from '@salesforce/apex/AntsuranceQuoteConfigurator.recheckAdvice';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { takeAnswers } from 'c/antsuranceSubmissionHandover';
import { keepTogether } from 'c/antsuranceText';

// Answers longer than this take a full row when read back.
const WIDE_ANSWER_LENGTH = 40;

// How a quote request can reach Antsurance. The values match Quote.Submission_Channel__c.
const CHANNELS = [
    { value: 'Phone', label: 'By phone', icon: 'utility:call', summary: 'Taken by phone' },
    { value: 'Online', label: 'Online', icon: 'utility:desktop', summary: 'Submitted online' },
    { value: 'Agent', label: 'Through an agent', icon: 'utility:people', summary: 'Sent in by an agent' },
    { value: 'In Person', label: 'In person', icon: 'utility:user', summary: 'Taken in person' }
];
const DEFAULT_CHANNEL = 'Phone';
// A question with up to this many choices shows them all as buttons; more go in a dropdown.
const MOST_BUTTONS = 4;
// Wait this long after the last change before asking for a new price.
const PRICE_DELAY_MS = 300;
// Wait this long on a step before asking Claude about it, so stepping straight through costs nothing.
const ADVICE_DELAY_MS = 700;
// How long the strip waits for Claude before it stops saying "reading" and quietly offers another try.
// The questions, the price and Next never wait on it. A late answer is still shown if the seller has not moved on.
const ADVICE_PATIENCE_MS = 20000;
const FALLBACK_ERROR = 'Something went wrong. Try again.';

/**
 * The quote configurator on the quote page. A new quote opens as a guided set of questions, one
 * section at a time, with the price updating alongside; a configured quote shows what was
 * answered and how the premium was built.
 */
// The answers and the price sit side by side from 46rem; under that they stack.
const NARROW_PX = 736;

export default class AntsuranceQuoteConfigurator extends NavigationMixin(LightningElement) {
    @api recordId;

    config;
    answers = {};
    pricing;
    channel = DEFAULT_CHANNEL;
    optionName = '';
    isEditing = false;
    // Where answers handed over from a broker's submission came from, in words.
    handedFrom;
    stepIndex = 0;
    isPricing = false;
    isSaving = false;
    // True once an answer has been changed, so cancelling a new quote can warn before throwing them away.
    isDirty = false;
    errorMessage;
    priceTimer;
    // Counts price requests so a slow, older answer cannot overwrite a newer one.
    priceRequest = 0;
    // Claude's suggestions for the answers so far. Each was checked and priced by the configurator on the server.
    suggestions = [];
    // On Review: a sentence the seller could say to put the option to the customer.
    pitch;
    // idle, loading, ready or failed. Nothing is shown when idle or failed.
    adviceState = 'idle';
    adviceTimer;
    advicePatienceTimer;
    adviceRequest = 0;
    // What Claude said for a step and a set of answers, so the same answers are never asked about twice.
    adviceCache = new Map();
    // Suggestions the seller has waved away, for as long as this page is open.
    dismissed = new Set();
    sparkUrl = CLAUDE_SPARK;

    // Below this width the answers and the price build-up no longer sit side by side. Read-only, they
    // then take a tab each, so the card stays about a screen tall.
    isNarrow = false;
    narrowTab = 'answers';
    widthWatcher;
    onWindowResize;

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
        this.onWindowResize = () => this.measure();
        window.addEventListener('resize', this.onWindowResize);
    }

    measure() {
        const width = this.template.host.getBoundingClientRect().width;
        if (width > 0 && width < NARROW_PX !== this.isNarrow) {
            this.isNarrow = width < NARROW_PX;
        }
    }

    get narrowTabs() {
        return [
            { value: 'answers', label: 'Answers' },
            { value: 'price', label: 'How the price is built' }
        ];
    }

    get gridClass() {
        return this.isNarrow ? `c-grid c-grid_show_${this.narrowTab}` : 'c-grid';
    }

    handleNarrowTab(event) {
        this.narrowTab = event.detail.value;
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.onWindowResize);
        this.widthWatcher?.disconnect();
        this.widthWatcher = undefined;
        clearTimeout(this.priceTimer);
        clearTimeout(this.adviceTimer);
        clearTimeout(this.advicePatienceTimer);
    }

    async load() {
        try {
            this.apply(await getConfiguration({ quoteId: this.recordId }));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    apply(config) {
        this.config = config;
        this.answers = JSON.parse(config.answersJson ?? '{}');
        this.pricing = config.pricing;
        this.channel = config.channel ?? DEFAULT_CHANNEL;
        this.optionName = config.optionName ?? '';
        // A quote nobody has answered yet opens straight into the questions.
        this.isEditing = !config.isConfigured && !config.isLocked && config.sections.length > 0;
        this.stepIndex = 0;
        this.isDirty = false;
        this.errorMessage = undefined;
        this.clearAdvice();
        this.handedFrom = undefined;
        if (this.isEditing) {
            this.takeHandover(config);
            this.scheduleAdvice();
        }
    }

    /**
     * Answers read from a broker's submission and confirmed by a person, left for this new quote by
     * "Read a submission". They are taken once, laid over the starting answers and priced here, and
     * nothing is saved until the seller saves the quote.
     */
    takeHandover(config) {
        const handed = takeAnswers(config.quoteId);
        if (!handed) {
            return;
        }
        const asked = new Set(config.sections.flatMap((section) => section.questions.map((question) => question.key)));
        const answers = Object.fromEntries(Object.entries(handed.answers).filter(([key]) => asked.has(key)));
        if (Object.keys(answers).length === 0) {
            return;
        }
        this.answers = { ...this.answers, ...answers };
        this.handedFrom = handed.from;
        this.isDirty = true;
        this.schedulePrice();
    }

    // ------------------------------------------------------------ state

    get isLoading() {
        return !this.config && !this.errorMessage;
    }

    get hasNoQuestions() {
        return this.config && (this.config.sections.length === 0 || (!this.config.isConfigured && this.config.isLocked));
    }

    get noQuestionsText() {
        return this.config.sections.length === 0
            ? 'There are no quote questions for this line of business yet.'
            : 'This quote was priced without the configurator, and it can no longer be changed.';
    }

    get eyebrow() {
        const { lineOfBusiness, customerName } = this.config;
        return customerName ? `${lineOfBusiness} quote for ${customerName}` : `${lineOfBusiness} quote`;
    }

    get sections() {
        return this.config.sections;
    }

    get isReview() {
        return this.stepIndex >= this.sections.length;
    }

    get isFirstStep() {
        return this.stepIndex === 0;
    }

    get currentSection() {
        return this.sections[this.stepIndex];
    }

    /** A quote nobody has saved yet: cancelling it discards the draft. */
    get isNew() {
        return !this.config.isConfigured;
    }

    /** Where a new quote's starting answers came from, so the seller confirms them and does not ask again. */
    get prefilledText() {
        if (this.isNew && this.handedFrom) {
            return `Started from ${this.handedFrom}. Check each answer before you save.`;
        }
        return this.isNew && this.config.prefilledFrom ? `Started from ${this.config.prefilledFrom}. Confirm each answer with the customer.` : undefined;
    }

    get canIssue() {
        return this.config.canIssue;
    }

    /** True when the answers carry a reason for an underwriter to look at the quote before it goes out. */
    get isReferred() {
        return (this.pricing?.referrals ?? []).length > 0;
    }

    get issueLabel() {
        return this.isReferred ? 'Save and send to underwriting' : 'Save and issue quote';
    }

    renderedCallback() {
        this.measure();
        // A tab that is not in front draws no frames, so the window's resize event is listened for as well.
        if (!this.widthWatcher && window.ResizeObserver) {
            this.widthWatcher = new ResizeObserver(() => this.measure());
            this.widthWatcher.observe(this.template.host);
        }
        if (!this.scrollToTop) {
            return;
        }
        this.scrollToTop = false;
        // After the browser has laid the new step out. The component's top carries a scroll margin that clears the page header.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.requestAnimationFrame(() => {
            this.refs.top?.scrollIntoView({ block: 'start' });
        });
    }

    get canEdit() {
        return !this.config.isLocked;
    }

    get lockedText() {
        return `Locked: the quote is ${this.config.status.toLowerCase()}`;
    }

    get channels() {
        return CHANNELS.map((option) => ({
            ...option,
            checked: option.value === this.channel ? 'true' : 'false',
            className: option.value === this.channel ? 'c-channel__option c-channel__option_on' : 'c-channel__option'
        }));
    }

    get channelIcon() {
        return CHANNELS.find((option) => option.value === this.channel)?.icon ?? 'utility:call';
    }

    get summaryMeta() {
        const how = CHANNELS.find((option) => option.value === this.config.channel)?.summary ?? 'Configured';
        const count = this.answerSections.reduce((total, section) => total + section.answers.length, 0);
        const when = this.config.configuredOn
            ? `, ${new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(`${this.config.configuredOn}T00:00:00`))}`
            : '';
        return `${how}${when}, ${count} answers`;
    }

    get steps() {
        const titles = [...this.sections.map((section) => section.title), 'Review'];
        return titles.map((title, index) => {
            let state = 'c-step';
            if (index === this.stepIndex) {
                state = 'c-step c-step_current';
            } else if (index < this.stepIndex) {
                state = 'c-step c-step_done';
            }
            return {
                key: `step-${index}`,
                index,
                title,
                badge: index + 1,
                className: state,
                current: index === this.stepIndex ? 'step' : undefined
            };
        });
    }

    get nextLabel() {
        const next = this.stepIndex + 1;
        return next >= this.sections.length ? 'Next: Review' : `Next: ${this.sections[next].title}`;
    }

    // ------------------------------------------------------------ questions

    /** What a question is currently set to: the answer given, or its default. */
    valueOf(question) {
        const given = this.answers[question.key];
        return given === undefined || given === null || given === '' ? (question.defaultValue ?? '') : given;
    }

    /** Some questions only apply after a particular answer to an earlier one. */
    isShown(question) {
        if (!question.showWhenKey) {
            return true;
        }
        return question.showWhenValues.includes(String(this.answers[question.showWhenKey] ?? ''));
    }

    get currentQuestions() {
        return this.currentSection.questions
            .filter((question) => this.isShown(question))
            .map((question) => {
                const value = String(this.valueOf(question));
                const hasOptions = question.options.length > 0;
                const isPills = hasOptions && question.options.length <= MOST_BUTTONS;
                const isCurrency = question.type === 'currency';
                const isNumber = question.type === 'number' || isCurrency;
                return {
                    key: question.key,
                    label: question.label,
                    ask: question.ask,
                    type: question.type,
                    value,
                    isPills,
                    isSelect: hasOptions && !isPills,
                    options: question.options.map((option) => ({
                        value: option.value,
                        label: option.label,
                        effect: option.effect,
                        checked: option.value === value ? 'true' : 'false',
                        className: option.value === value ? 'c-pill c-pill_on' : 'c-pill'
                    })),
                    selectOptions: question.options.map((option) => ({
                        value: option.value,
                        label: option.effect ? `${option.label} (${option.effect})` : option.label
                    })),
                    inputType: isNumber ? 'number' : 'text',
                    formatter: isCurrency ? 'currency' : undefined,
                    step: isCurrency ? '1000' : '1',
                    inputClass: isNumber ? 'c-question__input' : 'c-question__input c-question__input_wide'
                };
            });
    }

    /** Every answer in plain words, grouped by section, for the summary and the review step. */
    get answerSections() {
        const money = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 });
        return this.sections.map((section) => {
            const answers = section.questions
                .filter((question) => this.isShown(question))
                .map((question) => {
                    const raw = this.valueOf(question);
                    let value = String(raw);
                    if (question.options.length > 0) {
                        value = question.options.find((option) => option.value === String(raw))?.label ?? value;
                    } else if (question.type === 'currency' && raw !== '') {
                        value = money.format(Number(raw));
                    }
                    // A sentence-length answer, such as what the business does, gets a row to itself.
                    const className = value.length > WIDE_ANSWER_LENGTH ? 'c-answers__item c-answers__item_wide' : 'c-answers__item';
                    return { key: question.key, label: question.label, value, className };
                })
                // A free-text question nobody answered is left out rather than read back as a blank.
                .filter((answer) => answer.value !== '');
            return {
                key: section.key,
                title: section.title,
                count: `${answers.length} ${answers.length === 1 ? 'answer' : 'answers'}`,
                answers
            };
        });
    }

    // ------------------------------------------------------------ changes

    setAnswer(key, value) {
        this.isDirty = true;
        this.answers = { ...this.answers, [key]: value };
        this.schedulePrice();
    }

    handlePick(event) {
        const { key, value } = event.currentTarget.dataset;
        this.setAnswer(key, value);
    }

    handleInput(event) {
        const { key, type } = event.target.dataset;
        const value = event.detail.value;
        const isAmount = type === 'number' || type === 'currency';
        // A cleared amount falls back to the question's default rather than pricing as zero.
        this.setAnswer(key, isAmount && value !== '' ? Number(value) : value);
    }

    handleChannel(event) {
        this.channel = event.currentTarget.dataset.value;
    }

    handleName(event) {
        this.optionName = event.detail.value;
    }

    schedulePrice() {
        clearTimeout(this.priceTimer);
        this.isPricing = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.priceTimer = setTimeout(() => this.reprice(), PRICE_DELAY_MS);
    }

    async reprice() {
        this.priceRequest += 1;
        const request = this.priceRequest;
        try {
            const pricing = await price({
                lineOfBusiness: this.config.lineOfBusiness,
                answersJson: JSON.stringify(this.answers),
                tier: this.config.tier
            });
            if (request === this.priceRequest) {
                this.pricing = pricing;
                this.errorMessage = undefined;
                this.recheckSuggestions();
            }
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            if (request === this.priceRequest) {
                this.isPricing = false;
            }
        }
    }

    // ------------------------------------------------------------ Claude suggests

    /** The suggestions still on offer: those the seller has not waved away. */
    get shownSuggestions() {
        return this.suggestions.filter((item) => !this.dismissed.has(`${item.questionKey}=${item.value}`));
    }

    get pitchText() {
        return keepTogether(this.pitch);
    }

    /** One entry per step and set of answers. Keys are sorted so the same answers always read the same. */
    adviceKey() {
        const step = Math.min(this.stepIndex, this.sections.length);
        const answers = Object.keys(this.answers)
            .sort()
            .map((key) => `${key}=${this.answers[key]}`)
            .join('|');
        return `${step}|${answers}`;
    }

    clearAdvice() {
        clearTimeout(this.adviceTimer);
        clearTimeout(this.advicePatienceTimer);
        this.adviceRequest += 1;
        this.suggestions = [];
        this.pitch = undefined;
        this.adviceState = 'idle';
    }

    showAdvice(advice) {
        clearTimeout(this.advicePatienceTimer);
        this.suggestions = advice.suggestions ?? [];
        this.pitch = advice.pitch;
        if (!advice.failed) {
            this.adviceState = 'ready';
        } else {
            // Slow or busy: offer another try. Anything else (no access, a quote that cannot be read): say nothing at all.
            this.adviceState = advice.retryable ? 'failed' : 'idle';
        }
    }

    /**
     * Asks for suggestions once the step has been drawn and the seller has stayed on it a moment.
     * Nothing here holds up the questions: the strip fills in when the answer arrives.
     */
    scheduleAdvice() {
        clearTimeout(this.adviceTimer);
        clearTimeout(this.advicePatienceTimer);
        this.adviceRequest += 1;
        const cached = this.adviceCache.get(this.adviceKey());
        if (cached) {
            this.showAdvice(cached);
            return;
        }
        this.suggestions = [];
        this.pitch = undefined;
        this.adviceState = 'loading';
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.adviceTimer = setTimeout(() => this.requestAdvice(), ADVICE_DELAY_MS);
    }

    async requestAdvice() {
        this.adviceRequest += 1;
        const request = this.adviceRequest;
        const key = this.adviceKey();
        const asked = JSON.stringify(this.answers);
        clearTimeout(this.advicePatienceTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.advicePatienceTimer = setTimeout(() => {
            if (request === this.adviceRequest && this.adviceState === 'loading') {
                this.adviceState = 'failed';
            }
        }, ADVICE_PATIENCE_MS);
        try {
            const advice = await advise({ quoteId: this.recordId, answersJson: asked, tier: this.config.tier, stepIndex: this.stepIndex });
            if (!advice.failed) {
                this.adviceCache.set(key, advice);
            }
            if (request !== this.adviceRequest) {
                return;
            }
            this.showAdvice(advice);
            if (asked !== JSON.stringify(this.answers)) {
                // An answer changed while Claude was reading, so price the suggestions against the answers as they are now.
                this.recheckSuggestions();
            }
        } catch (error) {
            // A suggestion is a courtesy. When it cannot be had (the platform's own time limit, a dropped connection)
            // the strip offers another try and the quote carries on.
            if (request === this.adviceRequest) {
                this.clearAdvice();
                this.adviceState = 'failed';
            }
        }
    }

    /** After an answer changes: drop suggestions that no longer apply and price the rest again. Claude is not asked. */
    async recheckSuggestions() {
        if (this.suggestions.length === 0) {
            return;
        }
        const request = this.adviceRequest;
        const proposals = this.suggestions.map(({ kind, questionKey, value, title, why }) => ({ kind, questionKey, value, title, why }));
        try {
            const kept = await recheckAdvice({
                lineOfBusiness: this.config.lineOfBusiness,
                answersJson: JSON.stringify(this.answers),
                tier: this.config.tier,
                stepIndex: this.stepIndex,
                proposalsJson: JSON.stringify(proposals)
            });
            if (request === this.adviceRequest) {
                this.suggestions = kept;
            }
        } catch (error) {
            // Figures that cannot be confirmed are not shown.
            if (request === this.adviceRequest) {
                this.suggestions = [];
            }
        }
    }

    handleApplySuggestion(event) {
        const { questionKey, value } = event.detail;
        // Taken: it leaves the strip at once, and the others are priced again when the new premium arrives.
        this.suggestions = this.suggestions.filter((item) => item.questionKey !== questionKey);
        this.setAnswer(questionKey, value);
    }

    /** The seller asked for another try after a slow or failed call. */
    handleRetrySuggestions() {
        clearTimeout(this.adviceTimer);
        this.suggestions = [];
        this.pitch = undefined;
        this.adviceState = 'loading';
        this.requestAdvice();
    }

    handleDismissSuggestion(event) {
        const { questionKey, value } = event.detail;
        this.dismissed = new Set([...this.dismissed, `${questionKey}=${value}`]);
    }

    // ------------------------------------------------------------ moving through the steps

    goTo(index) {
        this.stepIndex = Math.min(Math.max(index, 0), this.sections.length);
        // Each step opens at its heading. The scroll waits for the new step to be drawn: scrolling first
        // left the view wherever the old step's height put it, which was the footer.
        this.scrollToTop = true;
        this.scheduleAdvice();
    }

    handleStep(event) {
        this.goTo(Number(event.currentTarget.dataset.index));
    }

    handleBack() {
        this.goTo(this.stepIndex - 1);
    }

    handleNext() {
        this.goTo(this.stepIndex + 1);
    }

    handleEdit() {
        this.isEditing = true;
        this.stepIndex = 0;
        // A saved quote shows the price it was saved at. Editing works from today's price for the same answers,
        // so every figure beside the questions (each option's effect, each suggestion) adds up to the premium shown.
        this.schedulePrice();
        this.scheduleAdvice();
    }

    async handleCancel() {
        if (!this.isNew) {
            if (this.isDirty) {
                const discard = await LightningConfirm.open({
                    label: 'Discard your changes?',
                    message: 'The answers you changed have not been saved. The quote stays as it was.',
                    theme: 'warning'
                });
                if (!discard) {
                    return;
                }
            }
            // Throw away unsaved changes and show the quote as it was saved.
            this.apply(this.config);
            return;
        }
        // A new quote has nothing saved to go back to, so cancelling removes the draft and returns to the sale.
        // Ask first once there is work to lose: an answer changed, or the seller is past the first step.
        if (this.isDirty || this.stepIndex > 0) {
            const confirmed = await LightningConfirm.open({
                label: 'Discard this quote?',
                message: 'The answers so far have not been saved. The draft quote will be removed from the sale.',
                theme: 'warning'
            });
            if (!confirmed) {
                return;
            }
        }
        this.isSaving = true;
        try {
            const opportunityId = await discardDraft({ quoteId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: opportunityId, objectApiName: 'Opportunity', actionName: 'view' }
            });
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isSaving = false;
        }
    }

    handleSave() {
        this.save(false);
    }

    handleSaveAndIssue() {
        this.save(true);
    }

    async save(issue) {
        this.isSaving = true;
        try {
            const saved = await saveConfiguration({
                quoteId: this.recordId,
                answersJson: JSON.stringify(this.answers),
                channel: this.channel,
                issue,
                optionName: this.optionName
            });
            const wasReferred = this.isReferred;
            this.apply(saved);
            // The premium, limit and deductible on the rest of the page come from the same record.
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: issue ? (wasReferred ? 'Sent to underwriting' : 'Quote issued') : 'Quote saved',
                    message: issue
                        ? wasReferred
                            ? 'The quote is saved as a draft and waits for an underwriter to decide.'
                            : 'The quote is issued and valid for 30 days.'
                        : 'The answers and the price are saved on the quote.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isSaving = false;
        }
    }
}
