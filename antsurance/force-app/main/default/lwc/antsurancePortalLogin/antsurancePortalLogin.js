import { LightningElement, api } from 'lwc';
import LOCKUP from '@salesforce/resourceUrl/antsuranceLockupOnWhite';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import { loadBrandFonts } from 'c/antsuranceFonts';

/**
 * The words and marks around the portal's sign-in form: who this is and what a customer can do once in, above
 * it, and who powers the assistant, below it. The form itself is Salesforce's own, restyled by the site's head
 * markup, so signing in stays Salesforce's job. This component shows no data and calls nothing.
 */
export default class AntsurancePortalLogin extends LightningElement {
    /** "head" for the part above the form, "foot" for the part below it. */
    @api place = 'head';
    lockup = LOCKUP;
    spark = SPARK;

    connectedCallback() {
        loadBrandFonts(this);
    }

    /** The last words are tied together, and the phone number kept whole, so no line ends on a stranded word. */
    get intro() {
        return 'Your policies, claims and requests in one place, with\u00A0Claude\u00A0to\u00A0help.';
    }

    get help() {
        return 'New here, or cannot get in? Call\u00A0us\u00A0at\u00A01\u2011800\u2011555\u20110142.';
    }

    get isHead() {
        return this.place !== 'foot';
    }
}
