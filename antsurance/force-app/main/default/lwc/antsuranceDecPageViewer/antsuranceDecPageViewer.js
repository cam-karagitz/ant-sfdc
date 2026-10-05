import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import POLICY_NUMBER from '@salesforce/schema/Policy__c.Name';

// The Visualforce page that prints the policy as a PDF.
const PDF_PAGE = '/apex/AntsuranceDecPage';
// Asks the browser's PDF viewer to hide its own toolbar and fit the page to the frame's width.
const VIEWER_OPTIONS = '#toolbar=0&navpanes=0&view=FitH';

/**
 * Shows a policy's declarations page, a PDF generated from the live record, as a page preview
 * with actions to open it in its own tab or download it.
 */
export default class AntsuranceDecPageViewer extends NavigationMixin(LightningElement) {
    /** The policy. Set automatically on a Policy record page. */
    @api recordId;
    isLoading = true;

    // Lets the component also be opened on its own: /lightning/cmp/c__antsuranceDecPageViewer?c__recordId=<Id>
    @wire(CurrentPageReference)
    pageReference;

    @wire(getRecord, { recordId: '$policyId', fields: [POLICY_NUMBER] })
    policy;

    get policyId() {
        return this.recordId ?? this.pageReference?.state?.c__recordId;
    }

    get isUnavailable() {
        return !this.policyId;
    }

    get policyNumber() {
        return getFieldValue(this.policy?.data, POLICY_NUMBER);
    }

    get caption() {
        const policy = this.policyNumber ? `policy ${this.policyNumber}` : 'this policy';
        return `Generated from ${policy} as it stands now.`;
    }

    get frameTitle() {
        return this.policyNumber ? `Declarations page for policy ${this.policyNumber}` : 'Declarations page';
    }

    get pdfUrl() {
        return `${PDF_PAGE}?id=${encodeURIComponent(this.policyId)}`;
    }

    get embedUrl() {
        return `${this.pdfUrl}${VIEWER_OPTIONS}`;
    }

    handleLoaded() {
        this.isLoading = false;
    }

    handleOpen() {
        this.openInNewTab(this.pdfUrl);
    }

    handleDownload() {
        this.openInNewTab(`${this.pdfUrl}&download=1`);
    }

    openInNewTab(url) {
        this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url } });
    }
}
