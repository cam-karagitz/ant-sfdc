import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import getRenewal from '@salesforce/apex/AntsuranceRenewalOutreachController.getRenewal';
import draft from '@salesforce/apex/AntsuranceRenewalOutreachController.draft';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';

const RISK_TONES = {
    Low: 'c-outreach__risk c-outreach__risk_low',
    Medium: 'c-outreach__risk c-outreach__risk_medium',
    High: 'c-outreach__risk c-outreach__risk_high'
};
const COPIED_FOR_MS = 2000;
// The email composer shows unstyled text in a serif. The draft goes in set in the app's own sans.
const EMAIL_STYLE = "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.5; color: #141413;";

/** Turns text into HTML-safe text, so a draft can go into the email composer's rich body as written. */
function escapeHtml(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Renewal outreach for a policy waiting on its renewal. It states what the renewal costs, and on
 * request has Claude draft what to say. The draft is not saved: it opens in the email composer or
 * is copied. On a policy that is not pending renewal the card renders nothing.
 */
export default class AntsuranceRenewalOutreach extends NavigationMixin(LightningElement) {
    @api recordId;
    renewal;
    outreach;
    isDrafting = false;
    errorMessage;
    copyLabel = 'Copy';

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRenewal, { policyId: '$recordId' })
    wiredRenewal({ data }) {
        if (data) {
            this.renewal = data;
        }
    }

    get isVisible() {
        return this.renewal?.isRenewing === true;
    }

    get firstName() {
        return (this.renewal?.insuredName ?? 'the insured').split(' ')[0];
    }

    /** "Expires Oct 29. Renewal premium $2,810, up $135." */
    get factsLine() {
        const { expires, currentPremium, renewalPremium } = this.renewal ?? {};
        const money = (value) => new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(value);
        const parts = [];
        if (expires) {
            // The date arrives as yyyy-mm-dd; noon keeps it on the same day in every time zone.
            const day = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' }).format(new Date(`${expires}T12:00:00`));
            parts.push(`Expires ${day}.`);
        }
        if (renewalPremium != null && currentPremium != null) {
            const change = Math.round(renewalPremium - currentPremium);
            let movement = 'unchanged';
            if (change > 0) {
                movement = `up ${money(change)}`;
            } else if (change < 0) {
                movement = `down ${money(-change)}`;
            }
            parts.push(`Renewal premium ${money(renewalPremium)}, ${movement}.`);
        } else {
            parts.push('The renewal has not been priced yet.');
        }
        return parts.join(' ');
    }

    get riskLabel() {
        return `${this.outreach.risk} risk of leaving`;
    }

    get riskClass() {
        return RISK_TONES[this.outreach.risk] ?? RISK_TONES.Medium;
    }

    get points() {
        return (this.outreach?.points ?? []).map((point, index) => ({ label: point.label, detail: keepTogether(point.detail), key: `${index}` }));
    }

    get riskReason() {
        return keepTogether(this.outreach?.riskReason);
    }

    get subject() {
        return keepTogether(this.outreach?.subject);
    }

    get callOpening() {
        return keepTogether(this.outreach?.callOpening);
    }

    /** The email as shown on the card. What is copied or sent to the composer uses the plain paragraphs. */
    get shownParagraphs() {
        return this.paragraphs.map((paragraph) => ({ key: paragraph.key, text: keepTogether(paragraph.text) }));
    }

    get paragraphs() {
        return (this.outreach?.body ?? '')
            .split(/\n\s*\n/)
            .map((text, index) => ({ key: `${index}`, text: text.trim() }))
            .filter((paragraph) => paragraph.text);
    }

    async handleDraft() {
        this.isDrafting = true;
        this.errorMessage = undefined;
        try {
            this.outreach = await draft({ policyId: this.recordId });
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The outreach could not be drafted. Try again.';
        } finally {
            this.isDrafting = false;
        }
    }

    /** Opens Salesforce's email composer on this policy with the draft in it. Nothing is sent until the person sends it. */
    handleEmail() {
        const html = this.paragraphs
            .map((paragraph) => `<p style="${EMAIL_STYLE} margin: 0 0 12px;">${escapeHtml(paragraph.text).replace(/\n/g, '<br>')}</p>`)
            .join('');
        this[NavigationMixin.Navigate]({
            type: 'standard__quickAction',
            attributes: { apiName: 'Global.SendEmail' },
            state: {
                recordId: this.recordId,
                defaultFieldValues: encodeDefaultFieldValues({ Subject: this.outreach.subject, HtmlBody: html, ToAddress: this.renewal.insuredEmail ?? '' })
            }
        });
    }

    async handleCopy() {
        const text = `Subject: ${this.outreach.subject}\n\n${this.outreach.body}`;
        try {
            await navigator.clipboard.writeText(text);
            this.copyLabel = 'Copied';
        } catch {
            this.copyLabel = 'Could not copy';
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.copyLabel = 'Copy';
        }, COPIED_FOR_MS);
    }
}
