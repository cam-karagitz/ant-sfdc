import { LightningElement, api } from 'lwc';
import { keepEndTogether, keepFiguresTogether } from 'c/antsurancePortalText';

const LINE_ICONS = [
    ['Auto', 'utility:travel_and_places'],
    ['Home', 'utility:home'],
    ['Renters', 'utility:home'],
    ['Umbrella', 'utility:shield'],
    ['Property', 'utility:company'],
    ['Liability', 'utility:shield'],
    ['Compensation', 'utility:people']
];

/** A leading hyphen in an amount is drawn as a true minus sign, which is as wide as the plus. */
function signed(figure) {
    return figure && figure.startsWith('-') ? `−${figure.slice(1)}` : figure;
}

/** Text with **bold** runs, as pieces the template can draw without reading any markup. */
function runs(text, key) {
    return text
        .split('**')
        .map((piece, index) => ({ key: `${key}-${index}`, text: piece, className: index % 2 === 1 ? 'c-words__strong' : '' }))
        .filter((run) => run.text);
}

/**
 * One block of Claude's answer on the customer portal. The server builds every block from the customer's own
 * records (AntsurancePortalClaude); this component only draws it. Each type has its own look, so an answer
 * reads as designed parts and never as stacked paragraphs or look-alike cards:
 *
 *   choices   options to press, one fact under each; pressing one raises `say` with the customer's reply
 *   policies  the policies as a ledger: icon, line and number, the yearly price, billing and renewal
 *   price     one policy's price as a receipt: signed lines, a ruled total, then what is paid when
 *   renewal   when one policy renews: the date as a calendar leaf, the time left, and the offer if there is one
 *   claim     where a claim stands: a five-part bar, then what happened last and what happens next
 *   coverage  what a policy covers: a checked list with each limit at the right
 *   note      one thing worth knowing, on an amber slip with a link
 *   text      words of Claude's own, with bold terms and lists
 *
 * A row or a link that goes somewhere raises `open` with { page, recordId }, as the portal's cards do.
 */
export default class AntsurancePortalBlock extends LightningElement {
    @api block;
    /** True once the conversation has moved on or Claude is answering: the options can no longer be pressed. */
    @api spent = false;

    get is() {
        const type = this.block?.type;
        return {
            choices: type === 'choices',
            policies: type === 'policies',
            price: type === 'price',
            renewal: type === 'renewal',
            claim: type === 'claim',
            coverage: type === 'coverage',
            note: type === 'note',
            text: type === 'text'
        };
    }

    get icon() {
        return this.lineIcon(this.block?.kind);
    }

    lineIcon(kind) {
        const match = LINE_ICONS.find(([word]) => (kind ?? '').includes(word));
        return match ? match[1] : 'utility:shield';
    }

    get tag() {
        return keepFiguresTogether(this.block?.tag);
    }

    get rows() {
        return (this.block?.rows ?? []).map((row, index) => ({
            ...row,
            key: `row-${index}`,
            icon: this.lineIcon(row.kind),
            tag: keepFiguresTogether(row.tag),
            sub: keepFiguresTogether(row.sub),
            note: keepFiguresTogether(row.note),
            figure: signed(row.figure),
            figureClass: row.kind === 'minus' ? 'c-line__figure c-line__figure_saving' : 'c-line__figure',
            label: `${row.label}`,
            openLabel: `Open your ${(row.label ?? '').toLowerCase()} policy ${row.tag ?? ''}`.trim()
        }));
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get facts() {
        return (this.block?.facts ?? []).map((fact, index) => ({
            ...fact,
            key: `fact-${index}`,
            figure: keepFiguresTogether(fact.figure),
            figureSub: keepFiguresTogether(fact.figureSub)
        }));
    }

    get hasFacts() {
        return this.facts.length > 0;
    }

    get footnote() {
        return keepEndTogether(this.block?.footnote);
    }

    get sub() {
        return keepFiguresTogether(this.block?.sub);
    }

    // ------------------------------------------------------------------------------- a renewal

    /** "Mar 17, 2027" as the three parts of a calendar leaf. */
    get leaf() {
        const [, month, day, year] = /^(\w+) (\d{1,2}), (\d{4})$/.exec(this.block?.sub ?? '') ?? [];
        return { month, day, year, whole: month !== undefined };
    }

    get renewsOn() {
        return keepFiguresTogether(`${this.block?.chip} ${this.block?.sub}`);
    }

    // ------------------------------------------------------------------------------- a claim

    get steps() {
        return (this.block?.steps ?? []).map((step, index) => ({ key: `step-${index}`, className: `c-progress__part c-progress__part_${step.state}` }));
    }

    /** "Step 2 of 5", or that every step is done. */
    get stepLabel() {
        const steps = this.block?.steps ?? [];
        const current = steps.findIndex((step) => step.state === 'current');
        return current < 0 ? 'Every step is done' : `Step ${current + 1} of ${steps.length}`;
    }

    get chipClass() {
        if (this.is.note) {
            return 'c-chip c-chip_watch';
        }
        if (this.block?.kind === 'closed') {
            return 'c-chip';
        }
        return this.block?.chip === 'Payment sent' ? 'c-chip c-chip_good' : 'c-chip c-chip_clay';
    }

    get latest() {
        return keepEndTogether(this.block?.latest);
    }

    get next() {
        return keepEndTogether(this.block?.next);
    }

    // ------------------------------------------------------------------------------- words

    /** A text block as paragraphs and lists. Lines that start with "- " or "1." are list items. */
    get parts() {
        const parts = [];
        let list;
        (this.block?.text ?? '').split('\n').forEach((raw, index) => {
            const line = raw.trim();
            const bullet = /^[-*•]\s+(.*)$/.exec(line);
            const numbered = /^\d+[.)]\s+(.*)$/.exec(line);
            const item = bullet ?? numbered;
            if (!line) {
                list = undefined;
            } else if (item) {
                const isOrdered = Boolean(numbered);
                if (!list || list.isOrdered !== isOrdered) {
                    list = { key: `part-${index}`, isList: true, isOrdered, isBulleted: !isOrdered, items: [] };
                    parts.push(list);
                }
                list.items.push({ key: `item-${index}`, runs: runs(keepEndTogether(item[1]), `item-${index}`) });
            } else {
                list = undefined;
                parts.push({ key: `part-${index}`, isList: false, runs: runs(keepEndTogether(line), `part-${index}`) });
            }
        });
        return parts;
    }

    // ------------------------------------------------------------------------------- events

    /** An option was pressed: it is sent as the customer's reply. */
    handleSay(event) {
        if (!this.spent) {
            this.dispatchEvent(new CustomEvent('say', { detail: { text: event.currentTarget.dataset.say } }));
        }
    }

    handleOpenRow(event) {
        const { page, record } = event.currentTarget.dataset;
        this.open(page, record);
    }

    handleOpen() {
        this.open(this.block.page, this.block.recordId);
    }

    open(page, recordId) {
        this.dispatchEvent(new CustomEvent('open', { detail: { page, recordId }, bubbles: true, composed: true }));
    }
}
