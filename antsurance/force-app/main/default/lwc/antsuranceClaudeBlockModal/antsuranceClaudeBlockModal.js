import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import { loadBrandFonts } from 'c/antsuranceFonts';

/**
 * One block from the chat at full size, over the page. The utility bar panel draws each block
 * small; its Expand button opens this, where the block is drawn as it is on the Ask Claude tab.
 * Open it with AntsuranceClaudeBlockModal.open({ size: 'large', label, kind, spec, blockId }).
 */
export default class AntsuranceClaudeBlockModal extends LightningModal {
    /** The block's kind: record, metrics, chart, work_list, form, draft, comparison or timeline. */
    @api kind;
    /** The block's checked content, as the chat received it. */
    @api spec;
    /** The tool call a form answers, passed back with its outcome. */
    @api blockId;
    // The modal has no heading band: the block carries its own title, and the modal's `label`
    // (which LightningModal requires) is what a screen reader announces.

    connectedCallback() {
        loadBrandFonts(this);
    }

    get isRecord() {
        return this.kind === 'record';
    }

    get isMetrics() {
        return this.kind === 'metrics';
    }

    get isChart() {
        return this.kind === 'chart';
    }

    get isWorkList() {
        return this.kind === 'work_list';
    }

    get isForm() {
        return this.kind === 'form';
    }

    get isDraft() {
        return this.kind === 'draft';
    }

    get isComparison() {
        return this.kind === 'comparison';
    }

    get isTimeline() {
        return this.kind === 'timeline';
    }

    /** A form saved or cancelled here is the same form as the one in the panel, so the chat is told. */
    handleFormDone(event) {
        this.dispatchEvent(new CustomEvent('formdone', { detail: event.detail }));
    }

    handleClose() {
        this.close();
    }
}
