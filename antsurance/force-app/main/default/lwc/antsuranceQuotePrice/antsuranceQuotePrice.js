import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';
import { keepTogether } from 'c/antsuranceText';

const MONTHS = 12;
// While the questions are being answered the panel shows this many of the largest steps; the rest are a click away.
const FOLDED_LINES = 5;
// An answer up to this long is kept on one line where a suggestion quotes it.
const SHORT_ANSWER = 24;
const NO_BREAK_SPACE = '\u00a0';

/** The price of a configured quote: the premium, its terms, any underwriting flags, and each step that built it. */
export default class AntsuranceQuotePrice extends LightningElement {
    /** The pricing returned by AntsuranceQuoteConfigurator. */
    @api pricing;
    /** True while a new price is on its way, so the figure can dim. */
    @api busy = false;
    /** Leaves out the premium and terms, for a page that already shows them elsewhere. */
    @api breakdownOnly = false;
    /** True while the questions are still being answered, so the breakdown reads as work in progress. */
    @api inProgress = false;
    /** True to list every step of the build-up even while answering, as the review step does. */
    @api showAll = false;
    /** Claude's suggestions for the answers so far, each already checked and priced by the configurator. */
    @api suggestions = [];
    /** idle (nothing asked yet), loading, ready, or failed. Idle shows nothing; failed shows only a quiet link to try again. */
    @api adviceState = 'idle';
    isOpen = false;
    sparkUrl = CLAUDE_SPARK;

    get heading() {
        return this.inProgress ? 'How the premium is built' : 'How the premium was built';
    }

    get showsTerms() {
        return !this.breakdownOnly;
    }

    get headingClass() {
        return this.breakdownOnly ? 'c-price__heading c-price__heading_first' : 'c-price__heading';
    }

    money(amount) {
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
    }

    get premium() {
        return this.pricing ? this.money(this.pricing.premium) : '';
    }

    get premiumClass() {
        return this.busy ? 'c-price__premium c-price__premium_busy' : 'c-price__premium';
    }

    get perMonth() {
        return this.pricing ? `a year, about ${this.money(this.pricing.premium / MONTHS)} a month` : '';
    }

    get limit() {
        const amount = this.pricing?.limitAmount;
        return amount === null || amount === undefined ? 'Not set' : this.money(amount);
    }

    get deductible() {
        const amount = this.pricing?.deductible;
        // A plan with no deductible reads "None", whether it is stored as blank or as zero.
        return amount ? this.money(amount) : 'None';
    }

    /** Shown while the questions are answered. On a saved quote the underwriting review card says why it was referred. */
    get hasReferrals() {
        return !this.breakdownOnly && (this.pricing?.referrals?.length ?? 0) > 0;
    }

    get referrals() {
        return this.pricing.referrals.map((text, index) => ({ key: `referral-${index}`, text }));
    }

    // ------------------------------------------------------------ Claude suggests

    /** The strip belongs to the questions being answered. It is silent until Claude has been asked, and when it could not be. */
    get showsAdvice() {
        return this.inProgress && (this.adviceState === 'loading' || this.adviceState === 'ready');
    }

    /** Claude was slow or could not be reached. No error is shown: a suggestion is a courtesy, so the seller is only offered another try. */
    get isAdviceFailed() {
        return this.inProgress && this.adviceState === 'failed';
    }

    get isAdviceLoading() {
        return this.adviceState === 'loading';
    }

    get hasSuggestions() {
        return (this.suggestions ?? []).length > 0;
    }

    /** Each suggestion in words: what to change, why, and what the configurator says it does to the premium. */
    get advice() {
        return (this.suggestions ?? []).map((item) => {
            const isAvoid = item.kind === 'avoid';
            // Measured against the premium on screen, so applying a suggestion moves the figure above by exactly what it says.
            const shown = this.pricing?.premium;
            const change = shown === undefined || shown === null || item.newPremium === undefined || item.newPremium === null ? (item.premiumChange ?? 0) : item.newPremium - shown;
            const amount = this.money(Math.abs(change));
            let effect = '';
            if (isAvoid) {
                if (change < 0) {
                    effect = `Would save ${amount} a year`;
                } else if (change > 0) {
                    effect = `Would add ${amount} a year`;
                }
            } else if (change < 0) {
                effect = `Saves ${amount} a year`;
            } else if (change > 0) {
                effect = `Adds ${amount} a year`;
            } else {
                effect = 'No change to the price';
            }
            const referrals = item.referrals ?? [];
            return {
                key: `${item.questionKey}=${item.value}`,
                questionKey: item.questionKey,
                value: item.value,
                isAvoid,
                canApply: !isAvoid,
                dismissLabel: isAvoid ? 'Got it' : 'Dismiss',
                className: isAvoid ? 'c-advice__item c-advice__item_avoid' : 'c-advice__item',
                title: keepTogether(item.title),
                why: keepTogether(item.why),
                move: keepTogether(
                    isAvoid
                        ? `${item.questionLabel}: stay at ${this.unbroken(item.fromLabel)}, not ${this.unbroken(item.toLabel)}.`
                        : `${item.questionLabel}: ${this.unbroken(item.fromLabel)} now, ${this.unbroken(item.toLabel)} suggested.`
                ),
                warning: referrals.length > 0 ? keepTogether(`Would go to an underwriter: ${referrals.join('; ')}.`) : undefined,
                effect,
                effectClass: !isAvoid && change < 0 ? 'c-advice__effect c-advice__effect_saving' : 'c-advice__effect'
            };
        });
    }

    /** A short answer such as "25 to 64" or "65 or older" reads as one item, so it does not break across lines. */
    unbroken(label) {
        const text = String(label ?? '');
        return text.length <= SHORT_ANSWER ? text.replace(/ /g, NO_BREAK_SPACE) : text;
    }

    handleApply(event) {
        const { key, value } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('applysuggestion', { detail: { questionKey: key, value } }));
    }

    handleRetry() {
        this.dispatchEvent(new CustomEvent('retrysuggestions'));
    }

    handleDismiss(event) {
        const { key, value } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('dismisssuggestion', { detail: { questionKey: key, value } }));
    }

    // ------------------------------------------------------------ the build-up

    /** Whether the build-up is longer than the folded panel shows. */
    get canFold() {
        return this.inProgress && !this.showAll && (this.pricing?.lines?.length ?? 0) > FOLDED_LINES;
    }

    get isFolded() {
        return this.canFold && !this.isOpen;
    }

    get isOpenLabel() {
        return this.isOpen ? 'true' : 'false';
    }

    get toggleLabel() {
        return this.isOpen ? 'Show the largest only' : `Show all ${this.pricing.lines.length} lines`;
    }

    handleToggle() {
        this.isOpen = !this.isOpen;
    }

    /** The steps to list: all of them, or the five that move the premium most, kept in their order. */
    get lines() {
        const all = this.allLines;
        if (!this.isFolded) {
            return all;
        }
        const largest = new Set(
            [...all]
                .sort((first, second) => second.size - first.size)
                .slice(0, FOLDED_LINES)
                .map((line) => line.key)
        );
        return all.filter((line) => largest.has(line.key));
    }

    get allLines() {
        return (this.pricing?.lines ?? []).map((line, index) => {
            const isBase = index === 0;
            const isCredit = line.amount < 0;
            // The base rate is an amount; every later step is what it added or took off.
            let amount = this.money(Math.abs(line.amount));
            if (!isBase) {
                amount = `${isCredit ? '-' : '+'}${amount}`;
            }
            // "Roof age: Over 20 years" reads better as the question with its answer underneath.
            // The base rate has no answer; what it was rated on goes underneath instead.
            const [title, ...rest] = line.label.split(': ');
            return {
                key: `line-${index}`,
                size: Math.abs(line.amount),
                title: keepTogether(title),
                detail: keepTogether(isBase ? line.effect : rest.join(': ')),
                effect: isBase ? '' : line.effect,
                amount,
                amountClass: isCredit ? 'c-price__line-amount c-price__line-amount_credit' : 'c-price__line-amount'
            };
        });
    }
}
