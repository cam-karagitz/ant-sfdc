import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { HEALTHY_LOSS_RATIO, HIGH_LOSS_RATIO, PLACEHOLDER, compactMoney, count, plural } from 'c/antsuranceCockpitFormat';

/**
 * Six slim figures about the book in one row. Each is a button that opens the list or the
 * dashboard the number comes from.
 */
export default class AntsuranceCockpitFigures extends NavigationMixin(LightningElement) {
    @api cockpit;

    connectedCallback() {
        loadBrandFonts(this);
    }

    get isLoading() {
        return this.cockpit ? 'false' : 'true';
    }

    get figures() {
        const figures = this.cockpit?.figures;
        const value = (text) => (figures ? text : PLACEHOLDER);
        let lossNote = 'Incurred over premium';
        let lossClass = 'c-figure__note';
        if (figures?.lossRatio != null) {
            if (figures.lossRatio <= HEALTHY_LOSS_RATIO) {
                lossNote = 'Healthy, under 70%';
                lossClass += ' c-figure__note_good';
            } else if (figures.lossRatio > HIGH_LOSS_RATIO) {
                lossNote = 'High, over 85%';
                lossClass += ' c-figure__note_alert';
            }
        }
        return [
            {
                key: 'policies',
                label: 'Policies in force',
                value: value(count(figures?.policiesInForce)),
                note: figures ? plural(figures.customerCount, 'customer') : '',
                list: 'Policy__c',
                filter: 'Active_Policies'
            },
            {
                key: 'premium',
                label: 'Premium in force',
                value: value(compactMoney(figures?.premiumInForce)),
                note: 'A year, on those policies',
                dashboard: 'book'
            },
            {
                key: 'claims',
                label: 'Open claims',
                value: value(count(figures?.openClaimCount)),
                note: figures ? `${count(figures.seriousClaimCount)} high or catastrophic` : '',
                list: 'Case',
                filter: 'Open_Claims'
            },
            {
                key: 'reserve',
                label: 'Outstanding reserve',
                value: value(compactMoney(figures?.outstandingReserve)),
                note: 'Still to pay on open claims',
                dashboard: 'claims'
            },
            {
                key: 'loss',
                label: 'Loss ratio',
                value: value(figures?.lossRatio == null ? PLACEHOLDER : `${figures.lossRatio}%`),
                note: lossNote,
                noteClass: lossClass,
                dashboard: 'executive'
            },
            {
                key: 'renewals',
                label: 'Renewing in 30 days',
                value: value(count(figures?.renewalsSoonCount)),
                note: figures ? `${compactMoney(figures.renewalsSoonPremium)} premium` : '',
                list: 'Policy__c',
                filter: 'Renewals_Next_60_Days'
            }
        ].map((figure) => ({
            ...figure,
            noteClass: figure.noteClass ?? 'c-figure__note',
            title: figure.dashboard ? `Open the dashboard behind ${figure.label.toLowerCase()}` : `Open the list behind ${figure.label.toLowerCase()}`
        }));
    }

    handleOpen(event) {
        const { list: objectApiName, filter: filterName, dashboard } = event.currentTarget.dataset;
        if (objectApiName) {
            this[NavigationMixin.Navigate]({ type: 'standard__objectPage', attributes: { objectApiName, actionName: 'list' }, state: { filterName } });
            return;
        }
        const recordId = this.cockpit?.dashboards?.[dashboard];
        this[NavigationMixin.Navigate](
            recordId
                ? { type: 'standard__recordPage', attributes: { recordId, objectApiName: 'Dashboard', actionName: 'view' } }
                : { type: 'standard__objectPage', attributes: { objectApiName: 'Dashboard', actionName: 'home' } }
        );
    }
}
