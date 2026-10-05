import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { renderMarkdown } from './markdown';

/**
 * Shows Markdown text as formatted content. Links to Salesforce records open with
 * in-app navigation; external links open in a new tab.
 */
export default class AntsuranceMarkdown extends NavigationMixin(LightningElement) {
    markdown = '';
    renderedMarkdown;

    @api
    get value() {
        return this.markdown;
    }
    set value(value) {
        this.markdown = value ?? '';
        this.renderContent();
    }

    renderedCallback() {
        this.renderContent();
    }

    renderContent() {
        const content = this.refs?.content;
        if (content && this.renderedMarkdown !== this.markdown) {
            this.renderedMarkdown = this.markdown;
            // renderMarkdown escapes the source and emits only its own tags.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            content.innerHTML = renderMarkdown(this.markdown);
        }
    }

    handleClick(event) {
        const link = event.target.closest('a');
        if (!link || event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        if (link.dataset.recordId) {
            event.preventDefault();
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: link.dataset.recordId, actionName: 'view' }
            });
        } else if (link.dataset.internal) {
            event.preventDefault();
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: { url: link.getAttribute('href') }
            });
        }
    }
}
