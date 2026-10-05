import { LightningElement, api, track } from 'lwc';
import getDocuments from '@salesforce/apex/AntsurancePortalDocuments.getDocuments';
import requestDocument from '@salesforce/apex/AntsurancePortalDocuments.request';
import getDocument from '@salesforce/apex/AntsurancePortalDocuments.getDocument';
import basePath from '@salesforce/community/basePath';

const ICONS = { declarations: 'utility:contract_doc', idCards: 'utility:identity' };
/** How long to wait for a copy to be printed, and how often to look for it. */
const LOOKS = 16;
const LOOK_EVERY = 2500;

/**
 * A policy's documents for its owner: the declarations page and, for an auto policy, the ID cards. They are
 * the same documents the internal org prints. A copy is made on request, shared with this customer alone,
 * and then read here a page at a time or downloaded.
 *
 * One row holds everything: which document (as tabs when there is more than one) on the left, what to do
 * with it on the right. The preview shows one page with a pager, so a long document never makes a long page.
 */
export default class AntsurancePortalDocuments extends LightningElement {
    @track documents = [];
    chosen;
    page = 0;
    isLoading = true;
    isMaking = false;
    failure;
    previewFailed = false;
    isLarge = false;
    tries = 0;
    policy;

    /** The policy whose documents to show. */
    @api
    get policyId() {
        return this.policy;
    }
    set policyId(value) {
        if (value && value !== this.policy) {
            this.policy = value;
            this.load();
        }
    }

    async load() {
        this.isLoading = true;
        this.failure = undefined;
        try {
            this.documents = await getDocuments({ policyId: this.policy });
            this.chosen = this.documents[0]?.key;
            this.page = 0;
            this.previewFailed = false;
        } catch (error) {
            this.failure = error?.body?.message ?? 'We could not load your documents.';
        } finally {
            this.isLoading = false;
        }
    }

    get hasDocuments() {
        return this.documents.length > 0;
    }

    get hasSeveral() {
        return this.documents.length > 1;
    }

    get tabs() {
        return this.documents.map((document) => ({
            key: document.key,
            label: document.label,
            icon: ICONS[document.key] ?? 'utility:file',
            selected: document.key === this.chosen ? 'true' : 'false',
            className: document.key === this.chosen ? 'c-docs__tab c-docs__tab_selected' : 'c-docs__tab'
        }));
    }

    get document() {
        return this.documents.find((entry) => entry.key === this.chosen);
    }

    get icon() {
        return ICONS[this.chosen] ?? 'utility:file';
    }

    get isReady() {
        return Boolean(this.document?.ready);
    }

    get madeLine() {
        const document = this.document;
        if (!document?.ready) {
            return document?.description;
        }
        const pages = document.pages > 1 ? `${document.pages} pages` : '1 page';
        return `${document.description} ${pages}, made ${document.madeText}.`;
    }

    handleTab(event) {
        this.choose(event.currentTarget.dataset.key);
    }

    handleTabKey(event) {
        const keys = this.documents.map((document) => document.key);
        const at = keys.indexOf(this.chosen);
        const to = { ArrowRight: (at + 1) % keys.length, ArrowLeft: (at - 1 + keys.length) % keys.length, Home: 0, End: keys.length - 1 }[event.key];
        if (to === undefined) {
            return;
        }
        event.preventDefault();
        this.choose(keys[to]);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(`.c-docs__tab[data-key="${keys[to]}"]`)?.focus(), 30);
    }

    choose(key) {
        this.chosen = key;
        this.failure = undefined;
        this.showPage(0);
    }

    // ------------------------------------------------------------------------------- getting a copy

    get makeLabel() {
        return this.isMaking ? 'Making your copy' : 'Get my copy';
    }

    async handleMake() {
        const key = this.chosen;
        this.isMaking = true;
        this.failure = undefined;
        try {
            let copy = await requestDocument({ policyId: this.policy, key });
            for (let look = 0; !copy.ready && look < LOOKS; look += 1) {
                // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
                await new Promise((resolve) => setTimeout(resolve, LOOK_EVERY));
                // eslint-disable-next-line no-await-in-loop
                copy = await getDocument({ policyId: this.policy, key });
            }
            if (copy.ready) {
                const ready = copy;
                this.documents = this.documents.map((entry) => (entry.key === key ? ready : entry));
                this.showPage(0);
            } else {
                this.failure = 'Your copy is taking longer than usual. Try again in a minute, or ask us to send it to you.';
            }
        } catch (error) {
            this.failure = error?.body?.message ?? 'We could not make your copy just now. Please try again.';
        } finally {
            this.isMaking = false;
        }
    }

    handleAskTeam() {
        this.dispatchEvent(new CustomEvent('open', { detail: { page: 'newRequest', recordId: this.policy }, bubbles: true, composed: true }));
    }

    // ------------------------------------------------------------------------------- reading it

    /** Files on a site are served under the site's own address. */
    get fileBase() {
        return `${basePath}/sfsites/c/sfc/servlet.shepherd`;
    }

    get downloadUrl() {
        return `${this.fileBase}/document/download/${this.document.documentId}?operationContext=S1`;
    }

    get pageUrl() {
        const again = this.tries ? `&try=${this.tries}` : '';
        return `${this.fileBase}/version/renditionDownload?rendition=SVGZ&versionId=${this.document.versionId}&operationContext=CHATTER&page=${this.page}${again}`;
    }

    get pageAlt() {
        return `${this.document.label}, page ${this.page + 1}`;
    }

    get pageCount() {
        return this.document?.pages ?? 1;
    }

    get hasPages() {
        return this.pageCount > 1;
    }

    get pageLabel() {
        return `Page ${this.page + 1} of ${this.pageCount}`;
    }

    get prevDisabled() {
        return this.page <= 0;
    }

    get nextDisabled() {
        return this.page >= this.pageCount - 1;
    }

    /** The page fits the window to start with. "Larger" shows it at the full width of the column, to read the small print. */
    handleSize() {
        this.isLarge = !this.isLarge;
    }

    get sizeLabel() {
        return this.isLarge ? 'Fit the page' : 'Larger';
    }

    get largePressed() {
        return this.isLarge ? 'true' : 'false';
    }

    get pageClass() {
        return this.isLarge ? 'c-docs__page c-docs__page_large' : 'c-docs__page';
    }

    handlePrev() {
        this.showPage(this.page - 1);
    }

    handleNext() {
        this.showPage(this.page + 1);
    }

    showPage(index) {
        this.page = Math.max(0, Math.min(index, this.pageCount - 1));
        this.tries = 0;
        this.previewFailed = false;
    }

    /** A page's picture is drawn the first time it is asked for, so a miss is tried again a few times before giving up. */
    handlePreviewError() {
        if (this.tries < 3) {
            const page = this.page;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                if (page === this.page) {
                    this.tries += 1;
                }
            }, 2000);
        } else {
            this.previewFailed = true;
        }
    }
}
