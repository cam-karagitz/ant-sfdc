import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';

const COPIED_MS = 2000;

const escapeHtml = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** An email or letter Claude wrote, set out as it will be sent, with Copy and Open as email. */
export default class AntsuranceClaudeDraft extends NavigationMixin(LightningElement) {
    /** { format, toName, toEmail, subject, body, relatedRecordId, emailRecordId } */
    @api spec;
    /** True in the utility bar panel: the subject and the opening lines, the rest on request. */
    @api compact = false;

    copyLabel = 'Copy';
    // Compact: whether the whole body is showing.
    showAll = false;

    get isLetter() {
        return this.spec?.format === 'letter';
    }

    get kindLabel() {
        return this.isLetter ? 'Draft letter' : 'Draft email';
    }

    get iconName() {
        return this.isLetter ? 'utility:page' : 'utility:email';
    }

    get subjectLabel() {
        return this.isLetter ? 'Re' : 'Subject';
    }

    get hasRecipient() {
        return Boolean(this.spec?.toName || this.spec?.toEmail);
    }

    /** Blank lines separate paragraphs; a single line break stays a line break. */
    get paragraphs() {
        return (this.spec?.body ?? '')
            .split(/\n\s*\n/)
            .map((text) => text.trim())
            .filter(Boolean)
            .map((text, index) => ({ key: `paragraph-${index}`, text }));
    }

    /** The composer logs the email against a record, so it is offered only when there is one it can open on. */
    get canEmail() {
        return !this.isLetter && Boolean(this.spec?.emailRecordId);
    }

    async handleCopy() {
        const heading = this.isLetter ? `Re: ${this.spec.subject}` : `Subject: ${this.spec.subject}`;
        try {
            await navigator.clipboard.writeText(`${heading}\n\n${this.spec.body}`);
            this.copyLabel = 'Copied';
        } catch {
            this.copyLabel = 'Could not copy';
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.copyLabel = 'Copy';
        }, COPIED_MS);
    }

    /** Opens Salesforce's own email composer with the draft in it. Nothing is sent until the user sends it. */
    handleEmail() {
        const html = this.paragraphs.map((paragraph) => `<p>${escapeHtml(paragraph.text).replace(/\n/g, '<br>')}</p>`).join('');
        this[NavigationMixin.Navigate]({
            type: 'standard__quickAction',
            attributes: { apiName: 'Global.SendEmail' },
            state: {
                recordId: this.spec.emailRecordId,
                defaultFieldValues: encodeDefaultFieldValues({ Subject: this.spec.subject, HtmlBody: html, ToAddress: this.spec.toEmail ?? '' })
            }
        });
    }

    get bodyClass() {
        return this.showAll ? 'c-draft__body c-draft__body_mini' : 'c-draft__body c-draft__body_mini c-draft__body_preview';
    }

    get toggleLabel() {
        return this.showAll ? 'Show less' : 'Show full draft';
    }

    get copyIcon() {
        return this.copyLabel === 'Copied' ? 'utility:check' : 'utility:copy';
    }

    get expandLabel() {
        return `Expand the ${this.kindLabel.toLowerCase()}`;
    }

    handleToggle() {
        this.showAll = !this.showAll;
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }
}
