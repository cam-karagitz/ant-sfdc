import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import { loadBrandFonts } from 'c/antsuranceFonts';

const NOON = 12;
const EVENING = 18;
const CHAT_TAB = 'Antsurance_Claude';

/**
 * The top of Home: who is here and what day it is, and a box that sends a question straight to
 * Claude. Asking opens the Ask Claude tab with the question already sent; the three ideas under
 * the box are written from today's numbers.
 */
export default class AntsuranceCockpitBar extends NavigationMixin(LightningElement) {
    /** The cockpit data from Apex. The bar draws without it and fills in when it arrives. */
    @api cockpit;
    sparkUrl = SPARK;

    connectedCallback() {
        loadBrandFonts(this);
    }

    get greeting() {
        const hour = new Date().getHours();
        let partOfDay = 'evening';
        if (hour < NOON) {
            partOfDay = 'morning';
        } else if (hour < EVENING) {
            partOfDay = 'afternoon';
        }
        const name = this.cockpit?.firstName;
        return name ? `Good ${partOfDay}, ${name}` : `Good ${partOfDay}`;
    }

    get today() {
        return new Intl.DateTimeFormat(LOCALE, { weekday: 'long', month: 'long', day: 'numeric' }).format(new Date());
    }

    /** Three questions worth asking today. The label is short; the question sent is whole. */
    get ideas() {
        const cockpit = this.cockpit;
        if (!cockpit) {
            return [];
        }
        const { figures, overdueTaskCount } = cockpit;
        return [
            overdueTaskCount > 0
                ? {
                      label: `${overdueTaskCount} overdue: where to start`,
                      question: `Which of my ${overdueTaskCount} overdue tasks should I do first, and why?`
                  }
                : { label: 'Where to start today', question: 'What should I work on first today?' },
            figures.renewalsSoonCount > 0
                ? {
                      label: 'Renewals at risk this month',
                      question: `Which of the ${figures.renewalsSoonCount} policies renewing in the next 30 days are most at risk of leaving?`
                  }
                : { label: 'Premium in force by line', question: 'Chart premium in force by line of business' },
            figures.seriousClaimCount > 0
                ? {
                      label: `${figures.seriousClaimCount} serious claims`,
                      question: 'Show the open high and catastrophic severity claims and what each one is waiting on'
                  }
                : { label: 'Loss ratio by line', question: 'Chart loss ratio by line of business' }
        ].map((idea, index) => ({ ...idea, key: `idea-${index}` }));
    }

    handleSubmit(event) {
        event.preventDefault();
        this.ask(this.refs.question.value);
    }

    handleIdea(event) {
        this.ask(event.currentTarget.dataset.question);
    }

    /** Opens the Ask Claude tab, which sends the question as soon as it arrives. */
    ask(question) {
        const text = (question ?? '').trim();
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: CHAT_TAB },
            state: text ? { c__ask: text } : {}
        });
        this.refs.question.value = '';
    }
}
