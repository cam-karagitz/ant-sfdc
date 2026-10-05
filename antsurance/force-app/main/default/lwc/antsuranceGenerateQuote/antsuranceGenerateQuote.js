import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import startQuote from '@salesforce/apex/AntsuranceQuoteConfigurator.startQuote';

/**
 * The Generate Quote button on a policy sale. It has no screen of its own: it starts a draft
 * quote and opens it, where the configurator walks through the questions.
 */
export default class AntsuranceGenerateQuote extends NavigationMixin(LightningElement) {
    @api recordId;
    isRunning = false;

    @api
    async invoke() {
        // A second click while the quote is being created would make two.
        if (this.isRunning) {
            return;
        }
        this.isRunning = true;
        try {
            const quoteId = await startQuote({ opportunityId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: quoteId, objectApiName: 'Quote', actionName: 'view' }
            });
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'The quote could not be started',
                    message: error?.body?.message ?? 'Try again, or ask an administrator to check your access to quotes.',
                    variant: 'error'
                })
            );
        } finally {
            this.isRunning = false;
        }
    }
}
