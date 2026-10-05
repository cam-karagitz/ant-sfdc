import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import { loadBrandFonts } from 'c/antsuranceFonts';

/**
 * The files on a chat message, over the page: its photos one at a time at the size they were sent, in
 * the shared carousel (buttons, arrow keys or a swipe), and its PDFs listed under them by name and size.
 * A PDF has no picture to show, so it never takes a slide of its own.
 * Open it with AntsuranceClaudeFileViewer.open({ size, label, files, startId }).
 */
export default class AntsuranceClaudeFileViewer extends LightningModal {
    /** [{ id, name, displayName, isImage, isPdf, previewUrl, kindLabel, sizeLabel }] */
    @api files = [];
    /** The id of the file to show first, when it is a photo. */
    @api startId;

    index = 0;
    placed = false;

    connectedCallback() {
        loadBrandFonts(this);
        this.index = Math.max(0, this.photos.findIndex((file) => file.id === this.startId));
    }

    renderedCallback() {
        // Open on the photo that was picked, once the carousel has its slides.
        if (!this.placed && this.index > 0 && this.refs.carousel) {
            this.placed = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.refs.carousel?.show(this.index), 0);
        }
    }

    get photos() {
        return this.files.filter((file) => file.isImage);
    }

    get documents() {
        return this.files.filter((file) => file.isPdf);
    }

    get hasPhotos() {
        return this.photos.length > 0;
    }

    get hasDocuments() {
        return this.documents.length > 0;
    }

    /** The photo in view, named above the carousel. */
    get photo() {
        return this.photos[this.index];
    }

    get documentsTitle() {
        const count = this.documents.length;
        const what = count === 1 ? 'PDF' : `${count} PDFs`;
        return this.hasPhotos ? `Also sent: ${count === 1 ? 'a PDF' : what}` : count === 1 ? 'PDF sent to Claude' : `${what} sent to Claude`;
    }

    handleSlide(event) {
        this.index = event.detail.index;
    }

    handleClose() {
        this.close();
    }
}
