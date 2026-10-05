import { LightningElement, api } from 'lwc';

/** The answers given in the quote configurator, one collapsible block per section. */
export default class AntsuranceQuoteAnswers extends LightningElement {
    /** [{ key, title, count, answers: [{ key, label, value, className }] }] */
    @api sections = [];
}
