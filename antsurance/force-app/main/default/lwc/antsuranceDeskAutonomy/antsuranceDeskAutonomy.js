import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import getDesk from '@salesforce/apex/AntsuranceDeskController.getDesk';
import saveAutonomy from '@salesforce/apex/AntsuranceDeskController.saveAutonomy';
import { loadBrandFonts } from 'c/antsuranceFonts';

const CHOICES = [
    { mode: 'auto', label: 'Does it and tells me' },
    { mode: 'approve', label: 'Prepares it for my approval' },
    { mode: 'off', label: 'Off' }
];

/**
 * How much Claude may do on its own, for each kind of work on Claude's desk. Work that moves money
 * or goes to a customer always waits for a person: that choice is shown locked, with the reason.
 * Closes with "saved" when the settings were changed.
 */
export default class AntsuranceDeskAutonomy extends LightningModal {
    @api label;
    settings;
    canManage = false;
    /** The modes as picked in the panel, by kind. */
    picked = {};
    isSaving = false;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
    }

    async load() {
        try {
            const desk = await getDesk();
            this.settings = desk.settings;
            this.canManage = desk.canManage;
            this.picked = Object.fromEntries(desk.settings.map((setting) => [setting.key, setting.mode]));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The settings could not be loaded.';
        }
    }

    get isReady() {
        return Boolean(this.settings);
    }

    get rows() {
        return (this.settings ?? []).map((setting) => {
            const mode = this.picked[setting.key];
            let means = 'Claude leaves this kind of work alone.';
            if (mode === 'auto') {
                means = setting.whenAuto;
            } else if (mode === 'approve') {
                means = setting.whenApprove;
            }
            return {
                ...setting,
                means,
                groupLabel: `How far Claude goes with ${setting.label.toLowerCase()}`,
                choices: CHOICES.map((choice) => {
                    const locked = setting.locked && choice.mode === 'auto';
                    const selected = choice.mode === mode;
                    let className = 'c-choice';
                    if (selected) {
                        className += ' c-choice_selected';
                    }
                    if (locked) {
                        className += ' c-choice_locked';
                    }
                    return {
                        ...choice,
                        key: `${setting.key}-${choice.mode}`,
                        kind: setting.key,
                        className,
                        checked: selected ? 'true' : 'false',
                        locked,
                        disabled: locked || !this.canManage
                    };
                })
            };
        });
    }

    get isUnchanged() {
        return (this.settings ?? []).every((setting) => this.picked[setting.key] === setting.mode);
    }

    get saveDisabled() {
        return !this.canManage || this.isUnchanged || this.isSaving;
    }

    handlePick(event) {
        const { kind, mode } = event.currentTarget.dataset;
        this.picked = { ...this.picked, [kind]: mode };
        this.errorMessage = undefined;
    }

    async handleSave() {
        this.isSaving = true;
        this.errorMessage = undefined;
        try {
            await saveAutonomy({ modesJson: JSON.stringify(this.picked) });
            this.close('saved');
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The settings could not be saved.';
        } finally {
            this.isSaving = false;
        }
    }

    handleCancel() {
        this.close('cancelled');
    }
}
