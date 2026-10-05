import { LightningElement, api, track } from 'lwc';
import checkPhoto from '@salesforce/apex/AntsurancePortalPhotos.check';
import addPhoto from '@salesforce/apex/AntsurancePortalPhotos.add';
import getPhotos from '@salesforce/apex/AntsurancePortalPhotos.getPhotos';
import viewPhoto from '@salesforce/apex/AntsurancePortalPhotos.view';
import SPARK from '@salesforce/resourceUrl/claudeSpark';

/** A claim takes this many photos from the portal, each redrawn to this size before it leaves the browser. */
const MAX_PHOTOS = 5;
const LONG_EDGE = 1280;
const MAX_BYTES = 380000;
const TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif'];
let nextKey = 0;

/**
 * Photos of the damage on a claim. It works in two places.
 *
 * In the claim form (no `claimId`): the customer adds photos, each is redrawn smaller in the browser, and
 * Claude looks at each one as it is added and says in a line whether it will help and what is still missing.
 * The photos wait here until the claim is filed; the form then calls `upload` with the new claim.
 *
 * On a claim's page (`claimId` set): the photos already on the claim are shown one at a time, and more can be
 * added, checked the same way and saved straight away.
 *
 * At most five photos a claim, shown one at a time with a count, so the page never grows with them.
 */
export default class AntsurancePortalPhotos extends LightningElement {
    /** The kind of loss and the customer's account, so Claude knows what the photos should show. */
    @api lossType;
    @api whatHappened;
    /** Whether photos can still be added. A closed claim takes none. */
    @api canAdd = false;

    @track photos = [];
    current = 0;
    isLoading = false;
    isWorking = false;
    notice;
    claim;
    spark = SPARK;

    /** The claim the photos are on. Leave unset inside the claim form, where the claim does not exist yet. */
    @api
    get claimId() {
        return this.claim;
    }
    set claimId(value) {
        if (value !== this.claim) {
            this.claim = value;
            if (value) {
                this.load();
            }
        }
    }

    async load() {
        this.isLoading = true;
        try {
            const saved = await getPhotos({ claimId: this.claim });
            this.photos = saved.map((photo) => ({ key: photo.id, id: photo.id, name: photo.name, shows: photo.name, addedText: photo.addedText, line: photo.note, saved: true }));
            this.current = 0;
            this.showCurrent();
        } catch (error) {
            this.notice = error?.body?.message ?? 'We could not load the photos.';
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------------------------- adding

    get isFull() {
        return this.photos.length >= MAX_PHOTOS;
    }

    get showAdd() {
        return (this.canAdd || !this.claim) && !this.isFull;
    }

    get intro() {
        return 'Photos help your adjuster settle a claim sooner. Claude checks each one is\u00A0clear as\u00A0you\u00A0add\u00A0it.';
    }

    get showNone() {
        return !this.isLoading;
    }

    get addLabel() {
        return this.photos.length ? 'Add another photo' : 'Add photos';
    }

    get roomLeft() {
        const left = MAX_PHOTOS - this.photos.length;
        return this.isFull ? 'That is the most a claim can take here. Your adjuster can take more by email.' : this.photos.length ? `${left} more can be added, up to ${MAX_PHOTOS} in all.` : `You can add up to ${MAX_PHOTOS} photos.`;
    }

    handleChoose() {
        this.template.querySelector('.c-photos__file')?.click();
    }

    async handleFiles(event) {
        const files = Array.from(event.target.files ?? []);
        event.target.value = '';
        this.notice = undefined;
        for (const file of files) {
            if (this.photos.length >= MAX_PHOTOS) {
                this.notice = `A claim can take up to ${MAX_PHOTOS} photos here. The rest were left out.`;
                break;
            }
            if (!TYPES.includes(file.type)) {
                this.notice = `"${file.name}" is not a photo we can read. Add a JPEG or PNG photo.`;
                continue;
            }
            // eslint-disable-next-line no-await-in-loop
            await this.take(file);
        }
    }

    /** Redraws one photo smaller, shows it, asks Claude about it, and on a claim's page saves it. */
    async take(file) {
        let data;
        try {
            data = await this.redraw(file);
        } catch (error) {
            this.notice = `"${file.name}" could not be read. Try another photo.`;
            return;
        }
        nextKey += 1;
        const photo = { key: `new-${nextKey}`, name: file.name, data, isChecking: true, saved: false };
        this.photos = [...this.photos, photo];
        this.current = this.photos.length - 1;
        this.announce();
        let check;
        try {
            check = await checkPhoto({
                base64Jpeg: data,
                lossType: this.lossType,
                whatHappened: this.whatHappened,
                shownSoFar: this.photos.filter((entry) => entry.key !== photo.key && entry.shows).map((entry) => entry.shows)
            });
        } catch (error) {
            check = { failed: true, usable: true, line: 'Claude could not look at this photo just now. You can still send it with your claim.' };
        }
        this.update(photo.key, { isChecking: false, line: check.line, usable: check.usable !== false, shows: check.shows, stillNeeded: check.stillNeeded, checkFailed: check.failed });
        if (this.claim) {
            await this.save(photo.key);
        }
        this.announce();
    }

    update(key, changes) {
        this.photos = this.photos.map((photo) => (photo.key === key ? { ...photo, ...changes } : photo));
    }

    async save(key) {
        const photo = this.photos.find((entry) => entry.key === key);
        if (!photo || photo.saved) {
            return true;
        }
        this.update(key, { isSaving: true });
        try {
            const saved = await addPhoto({ claimId: this.claim, base64Jpeg: photo.data, shows: photo.shows, note: photo.checkFailed ? '' : photo.line });
            this.update(key, { isSaving: false, saved: true, id: saved.id, name: saved.name, addedText: saved.addedText });
            return true;
        } catch (error) {
            this.update(key, { isSaving: false, failure: error?.body?.message ?? 'That photo could not be added. Please try again.' });
            return false;
        }
    }

    /**
     * Saves the photos waiting here to a claim that has just been filed. Called by the claim form.
     * @param {string} claimId The new claim
     * @returns {Promise<{added: number, failed: number}>} How many were saved and how many were not
     */
    @api
    async upload(claimId) {
        this.claim = claimId;
        let added = 0;
        let failed = 0;
        this.isWorking = true;
        for (const photo of this.photos.filter((entry) => !entry.saved)) {
            // One photo a request, so no request comes near Apex's memory limit.
            // eslint-disable-next-line no-await-in-loop
            if (await this.save(photo.key)) {
                added += 1;
            } else {
                failed += 1;
            }
        }
        this.isWorking = false;
        return { added, failed };
    }

    /** How many photos are waiting or saved, and what Claude said is still missing, for the form and for Claude. */
    @api
    summary() {
        const usable = this.photos.filter((photo) => photo.usable !== false).length;
        return { count: this.photos.length, usable, stillNeeded: this.latestNeed };
    }

    announce() {
        this.dispatchEvent(new CustomEvent('photoschange', { detail: this.summary() }));
    }

    /**
     * Redraws a photo so its long edge is at most 1,280 pixels and it is under about 380 KB, as a JPEG.
     * A phone photo is several megabytes; this is what lets it be checked and saved.
     */
    redraw(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onerror = () => reject(new Error('unreadable'));
            reader.onload = () => {
                const image = new Image();
                image.onerror = () => reject(new Error('not an image'));
                image.onload = () => {
                    const scale = Math.min(1, LONG_EDGE / Math.max(image.width, image.height));
                    const canvas = document.createElement('canvas');
                    canvas.width = Math.max(1, Math.round(image.width * scale));
                    canvas.height = Math.max(1, Math.round(image.height * scale));
                    const context = canvas.getContext('2d');
                    context.fillStyle = '#fff';
                    context.fillRect(0, 0, canvas.width, canvas.height);
                    context.drawImage(image, 0, 0, canvas.width, canvas.height);
                    let quality = 0.82;
                    let data = canvas.toDataURL('image/jpeg', quality);
                    // A base64 character carries six bits, so the bytes are three quarters of the text.
                    while (data.length * 0.75 > MAX_BYTES && quality > 0.4) {
                        quality -= 0.1;
                        data = canvas.toDataURL('image/jpeg', quality);
                    }
                    resolve(data);
                };
                image.src = reader.result;
            };
            reader.readAsDataURL(file);
        });
    }

    // ------------------------------------------------------------------------------- one at a time

    get hasPhotos() {
        return this.photos.length > 0;
    }

    get shown() {
        const photo = this.photos[Math.min(this.current, this.photos.length - 1)];
        if (!photo) {
            return undefined;
        }
        return {
            ...photo,
            src: photo.data,
            alt: photo.shows || photo.name || 'Photo of the damage',
            lineClass: photo.usable === false ? 'c-photos__line c-photos__line_retake' : 'c-photos__line',
            canRemove: !photo.saved && !photo.isSaving,
            status: photo.isSaving ? 'Adding it to your claim' : photo.saved && photo.addedText ? `On your claim since ${photo.addedText}` : ''
        };
    }

    get count() {
        return `${Math.min(this.current + 1, this.photos.length)} of ${this.photos.length}`;
    }

    get thumbs() {
        return this.photos.map((photo, index) => ({
            key: photo.key,
            index,
            src: photo.data,
            label: `Photo ${index + 1}${photo.shows ? `: ${photo.shows}` : ''}`,
            number: index + 1,
            className: 'c-photos__thumb' + (index === this.current ? ' c-photos__thumb_current' : '') + (photo.usable === false ? ' c-photos__thumb_retake' : ''),
            current: index === this.current ? 'true' : 'false'
        }));
    }

    get prevDisabled() {
        return this.current <= 0;
    }

    get nextDisabled() {
        return this.current >= this.photos.length - 1;
    }

    get hasSeveral() {
        return this.photos.length > 1;
    }

    /** What Claude said would still help, from its most recent look. */
    get latestNeed() {
        const checked = [...this.photos].reverse().find((photo) => photo.line && !photo.checkFailed && !photo.isChecking);
        return checked?.stillNeeded ?? '';
    }

    handlePrev() {
        this.go(this.current - 1);
    }

    handleNext() {
        this.go(this.current + 1);
    }

    handleThumb(event) {
        this.go(Number(event.currentTarget.dataset.index));
    }

    /** Left and right arrows move between photos while the viewer has the keyboard. */
    handleKey(event) {
        if (event.key === 'ArrowLeft') {
            this.go(this.current - 1);
        } else if (event.key === 'ArrowRight') {
            this.go(this.current + 1);
        }
    }

    go(index) {
        this.current = Math.max(0, Math.min(index, this.photos.length - 1));
        this.showCurrent();
    }

    /** A photo saved earlier is fetched when it is first looked at, and kept. */
    async showCurrent() {
        const photo = this.photos[this.current];
        if (!photo || photo.data || !photo.id || photo.isFetching) {
            return;
        }
        this.update(photo.key, { isFetching: true });
        try {
            const data = await viewPhoto({ claimId: this.claim, photoId: photo.id });
            this.update(photo.key, { isFetching: false, data: `data:image/jpeg;base64,${data}` });
        } catch (error) {
            this.update(photo.key, { isFetching: false, failure: 'This photo could not be shown.' });
        }
    }

    handleRemove() {
        const photo = this.photos[this.current];
        if (photo && !photo.saved) {
            this.photos = this.photos.filter((entry) => entry.key !== photo.key);
            this.current = Math.max(0, Math.min(this.current, this.photos.length - 1));
            this.announce();
        }
    }
}
