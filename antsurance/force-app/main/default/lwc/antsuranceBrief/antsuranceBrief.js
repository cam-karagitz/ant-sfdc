import { LightningElement, api } from 'lwc';
import { keepTogether } from 'c/antsuranceText';

// Text with a Markdown link in it is left alone, so nothing inside the link's address is changed.
const unbroken = (text) => (text.includes('](') ? text : keepTogether(text));

// A paragraph that opens with a bold label and a colon, such as "**Watch:** the roof is original."
const LABELLED = /^\*\*([^*\n]{1,32}?):?\*\*:?\s*([\s\S]+)$/;
// Icons by what a label is about. Anything else gets the note icon.
const TOPICS = [
    { words: ['watch', 'caution', 'concern', 'exclusion', 'warning'], icon: 'utility:warning', alert: true },
    { words: ['risk', 'hazard', 'exposure', 'condition'], icon: 'utility:shield' },
    { words: ['who', 'customer', 'insured', 'household', 'business', 'about', 'operations'], icon: 'utility:people' },
    { words: ['want', 'need', 'request'], icon: 'utility:cart' },
    { words: ['why', 'reason', 'background'], icon: 'utility:info' },
    { words: ['service', 'contact', 'prefer'], icon: 'utility:call' },
    { words: ['include', 'cover', 'protection', 'limit'], icon: 'utility:shield' },
    { words: ['difference', 'pricing', 'premium', 'rate', 'cost', 'reserve', 'paid', 'payment'], icon: 'utility:moneybag' },
    { words: ['renewal', 'term', 'date', 'timeline'], icon: 'utility:event' },
    { words: ['status', 'done', 'decision', 'approved', 'received'], icon: 'utility:check' },
    { words: ['next', 'outstanding', 'needed', 'action', 'waiting'], icon: 'utility:clock' },
    { words: ['location', 'property', 'building', 'premises'], icon: 'utility:location' }
];

// Labels that read better said another way. The stored text keeps its own wording.
const LABEL_WORDING = { position: 'Why this option' };

/**
 * Renders a written brief. Paragraphs that open with a bold label ("**Who:** ...") become labelled
 * points, each with an icon and its label on a line of its own; anything else is plain Markdown.
 */
export default class AntsuranceBrief extends LightningElement {
    @api value;

    get blocks() {
        return (this.value ?? '')
            .split(/\n\s*\n/)
            .map((text) => text.trim())
            .filter(Boolean)
            .map((text, index) => {
                const match = LABELLED.exec(text);
                if (!match) {
                    return { key: `block-${index}`, body: unbroken(text), rowClass: 'c-point c-point_plain' };
                }
                const written = match[1].trim();
                const label = LABEL_WORDING[written.toLowerCase()] ?? written;
                const topic = TOPICS.find(({ words }) => words.some((word) => written.toLowerCase().includes(word)));
                return {
                    key: `block-${index}`,
                    label,
                    body: unbroken(match[2].trim()),
                    icon: topic?.icon ?? 'utility:note',
                    rowClass: topic?.alert ? 'c-point c-point_alert' : 'c-point'
                };
            });
    }

    /** Labelled points are worth the richer layout; a brief without any reads better as plain Markdown. */
    get hasPoints() {
        return this.blocks.some((block) => block.label);
    }
}
