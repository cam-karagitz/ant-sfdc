import { LightningElement, api, track } from 'lwc';
import askClaude from '@salesforce/apex/AntsurancePortalClaude.ask';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import { keepEndTogether, keepFiguresTogether, endsOnShortLine } from 'c/antsurancePortalText';

let nextId = 0;
const TOOK_TOO_LONG = 'That took longer than it should have. Your message is saved here, so try again, or send it to our team and a person will reply.';

/**
 * Claude for customers. It holds the conversation, shows each of Claude's replies as a short lead with the
 * blocks the server built under it (choices, a policy list, a price breakdown, a claim's status and so on,
 * each drawn by c-antsurance-portal-block), and hands any actions Claude asks for (go to a page, fill the
 * form, point at a field) to the portal app through an `actions` event. The app does them and reports back
 * through `note`, so the conversation knows what happened on the page.
 *
 * The conversation lives in this component only: nothing is kept in the browser's storage, so `reset`
 * starts it over completely. It raises `talk` with how many messages it holds whenever that changes.
 */
export default class AntsurancePortalChat extends LightningElement {
    /** What the customer is looking at: the page, the record and any form, as the app describes it. Sent with every message. */
    @api screen;
    /** The customer's first name, for the greeting. */
    @api firstName;
    /** Things to ask, shown before the conversation starts. */
    @api starters = [];

    @track messages = [];
    @track openReceipts = [];
    /** Paragraphs that ended on a short last line when drawn, so their last words are tied together. */
    @track tied = [];
    measured = new Set();
    measuredWidth = 0;
    draft = '';
    isBusy = false;
    failure;
    spark = SPARK;
    /** Counts conversations. An answer that arrives for a conversation since started over is let go. */
    generation = 0;

    get isEmpty() {
        return this.messages.length === 0;
    }

    get greeting() {
        return this.firstName ? `Hi ${this.firstName}. What can I help with?` : 'What can I help with?';
    }

    get turns() {
        const last = this.messages.length - 1;
        const lastAsked = this.messages.map((message) => message.role).lastIndexOf('customer');
        return this.messages.map((message, index) => ({
            ...message,
            // Options belong to the question they were asked for: once the customer has answered, or while Claude is answering, they rest.
            blocks: (message.blocks ?? []).map((block, position) => ({ key: `${message.id}-b${position}`, block, spent: this.isBusy || index < lastAsked })),
            isCustomer: message.role === 'customer',
            isClaude: message.role === 'claude',
            isSite: message.role === 'site',
            receipt: (message.receipt ?? []).map((line, position) => {
                const key = `${message.id}-r${position}`;
                const isOpen = this.openReceipts.includes(key);
                const needed = line.needed ?? [];
                return {
                    ...line,
                    key,
                    isOpen,
                    hasFields: (line.fields ?? []).length > 0,
                    toggleLabel: isOpen ? 'Hide' : 'Show',
                    chips: (line.fields ?? []).map((label) => ({ key: `${key}-${label}`, label })),
                    hasNeeded: needed.length > 0,
                    needs: needed.map((field) => ({ key: `${key}-${field.name}`, name: field.name, label: field.label }))
                };
            }),
            paragraphs: (message.text ?? '')
                .split(/\n\s*\n/)
                .map((text, position) => {
                    const key = `${message.id}-${position}`;
                    // Lines fill the bubble; the last words are tied only where the paragraph was seen to end on a short line.
                    return { key, text: this.tied.includes(key) ? keepEndTogether(text.trim()) : keepFiguresTogether(text.trim()) };
                })
                .filter((paragraph) => paragraph.text),
            // Follow-ups belong to the latest reply only.
            followUps: index === last && !this.isBusy ? (message.suggestions ?? []).map((text) => ({ key: text, text })) : []
        }));
    }

    get sendDisabled() {
        return this.isBusy || !this.draft.trim();
    }

    /**
     * Sends a message for the customer, as if they had typed it.
     * @param {string} text The message
     */
    @api
    ask(text) {
        const message = (text ?? '').trim();
        if (!message || this.isBusy) {
            return;
        }
        this.push('customer', message);
        this.draft = '';
        this.send();
    }

    /**
     * Records what the site did after Claude asked for it, or what the customer did on a page (sent a form).
     * It is shown as a quiet line and Claude reads it with the next message.
     * @param {string} text What happened, in full, for Claude
     * @param {{text: string, fields?: string[], needed?: {name: string, label: string}[], page?: string}[]} [receipt]
     *   What the customer sees: one short line for each thing done, the fields filled (behind Show), and what is still needed
     */
    @api
    note(text, receipt) {
        if (text) {
            this.push('site', text, { receipt: receipt ?? [{ text }] });
        }
    }

    /**
     * Starts the conversation over: every message, any failure and anything half typed are cleared, and the
     * greeting returns. Only the conversation is touched. A form on the page keeps what is in it, whether the
     * customer typed it or Claude filled it in. An answer still on its way for the old conversation is let go.
     */
    @api
    reset() {
        this.generation += 1;
        this.messages = [];
        this.openReceipts = [];
        this.tied = [];
        this.measured = new Set();
        this.failure = undefined;
        this.isBusy = false;
        this.draft = '';
        const input = this.template.querySelector('.c-chat__input');
        if (input) {
            input.value = '';
            input.focus();
        }
        this.tell();
    }

    push(role, text, extra = {}) {
        nextId += 1;
        this.messages = [...this.messages, { id: `m${nextId}`, role, text, ...extra }];
        this.tell();
        this.scrollDown();
    }

    /** Lets the portal know whether there is a conversation, so it can offer to start a new one. */
    tell() {
        this.dispatchEvent(new CustomEvent('talk', { detail: { count: this.messages.length } }));
    }

    async send() {
        const generation = this.generation;
        this.isBusy = true;
        this.failure = undefined;
        this.scrollDown();
        try {
            // Claude reads what it said and, in brackets, what the site drew under it.
            const conversation = this.messages.map((message) => ({
                role: message.role,
                text: [message.text, ...(message.blocks ?? []).map((block) => `[${block.summary}]`)].filter(Boolean).join(' ')
            }));
            const reply = await askClaude({ conversationJson: JSON.stringify(conversation), screenJson: JSON.stringify(this.screen ?? {}) });
            if (generation !== this.generation) {
                return;
            }
            if (reply.failed) {
                // The conversation, including what they just typed, stays as it is. Only a calm line is added.
                this.failure = reply.text;
                return;
            }
            this.push('claude', reply.text, { blocks: reply.blocks ?? [], suggestions: reply.suggestions });
            if (reply.actions?.length) {
                this.dispatchEvent(new CustomEvent('actions', { detail: { actions: reply.actions } }));
            }
        } catch (error) {
            // Anything else (the request itself failing or running out of time) gets the same calm line, never the raw error.
            if (generation === this.generation) {
                this.failure = TOOK_TOO_LONG;
            }
        } finally {
            if (generation === this.generation) {
                this.isBusy = false;
                this.scrollToQuestion();
            }
        }
    }

    /** After an answer, put the customer's question at the top so the answer is read from its start. */
    scrollToQuestion() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const list = this.template.querySelector('.c-chat__list');
            const questions = this.template.querySelectorAll('.c-chat__mine');
            const last = questions[questions.length - 1];
            if (list && last) {
                list.scrollTop = Math.max(0, last.offsetTop - 12);
            }
        }, 60);
    }

    /** After each draw, look at Claude's paragraphs once: any that ends on a stranded word or two gets its last words tied. */
    renderedCallback() {
        const list = this.template.querySelector('.c-chat__list');
        if (!list) {
            return;
        }
        // A different width wraps differently, so look again.
        if (list.clientWidth !== this.measuredWidth) {
            this.measuredWidth = list.clientWidth;
            this.measured = new Set();
            if (this.tied.length) {
                this.tied = [];
                return;
            }
        }
        const found = [];
        this.template.querySelectorAll('.c-chat__text[data-key]').forEach((paragraph) => {
            const key = paragraph.dataset.key;
            if (!this.measured.has(key)) {
                this.measured.add(key);
                if (endsOnShortLine(paragraph)) {
                    found.push(key);
                }
            }
        });
        if (found.length) {
            this.tied = [...this.tied, ...found];
        }
    }

    scrollDown() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const list = this.template.querySelector('.c-chat__list');
            if (list) {
                list.scrollTop = list.scrollHeight;
            }
        }, 30);
    }

    handleDraft(event) {
        this.draft = event.target.value;
    }

    handleKey(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSend();
        }
    }

    handleSend() {
        const input = this.template.querySelector('.c-chat__input');
        this.ask(this.draft);
        if (input) {
            input.value = '';
        }
    }

    handleSuggestion(event) {
        this.ask(event.currentTarget.dataset.text);
    }

    /** An option of a choices block was pressed: it is the customer's reply. */
    handleSay(event) {
        this.ask(event.detail.text);
    }

    handleToggleReceipt(event) {
        const key = event.currentTarget.dataset.key;
        const opening = !this.openReceipts.includes(key);
        this.openReceipts = opening ? [...this.openReceipts, key] : this.openReceipts.filter((entry) => entry !== key);
        if (opening) {
            // Bring what was just opened into view.
            const item = event.currentTarget.closest('.c-receipt__item');
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => item?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }), 40);
        }
    }

    /** Takes the customer to the first field still needed. */
    handleNeeded(event) {
        const { page, name } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('actions', { detail: { actions: [{ type: 'point', page, target: name }], quiet: true } }));
    }

    handleRetry() {
        this.send();
    }

    /** Opens the request form with the customer's unanswered message already in it, so a person can reply instead. */
    handleSendToTeam() {
        const last = [...this.messages].reverse().find((message) => message.role === 'customer');
        this.failure = undefined;
        this.dispatchEvent(
            new CustomEvent('actions', {
                detail: {
                    actions: [
                        { type: 'fill', page: 'newRequest', fields: [{ name: 'details', value: last?.text ?? '' }], say: 'Opening a request to our team with your message in it.' }
                    ],
                    fromCustomer: true
                }
            })
        );
    }
}
