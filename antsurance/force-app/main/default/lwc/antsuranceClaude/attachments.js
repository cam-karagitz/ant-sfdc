/**
 * Photos and PDFs attached to a message in the chat: reading a file, redrawing a photo small enough to
 * send, and the limits, checked here before anything leaves the browser. The same limits are checked
 * again in Apex (AntsuranceClaudeAttachments), which is where they are explained.
 */
export const LIMITS = { files: 4, imageBytes: 600000, pdfBytes: 900000, totalBytes: 1200000 };
export const ACCEPT = 'image/jpeg,image/png,image/webp,image/gif,application/pdf';

const PDF = 'application/pdf';
const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const TYPE_BY_EXTENSION = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', gif: 'image/gif', pdf: PDF };
// The longest side Claude reads at full detail; a larger photo only costs time.
const LONG_EDGE = 1568;
// The small picture shown in the composer and on the sent message.
const THUMB_EDGE = 160;
const SHRINK_ATTEMPTS = 7;
const BASE64_RATIO = 0.75;

let nextId = 0;

export function sizeLabel(bytes) {
    return bytes < 1000000 ? `${Math.max(1, Math.round(bytes / 1000))} KB` : `${(bytes / 1000000).toFixed(1)} MB`;
}

/** A file's type, from what the browser says or, failing that, its name. */
function typeOf(file) {
    if (file.type) {
        return file.type === 'image/jpg' ? 'image/jpeg' : file.type;
    }
    return TYPE_BY_EXTENSION[(file.name ?? '').split('.').pop().toLowerCase()];
}

function readAsDataUrl(blob, name) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error(`"${name}" could not be read. Try attaching it again.`));
        reader.readAsDataURL(blob);
    });
}

function loadImage(dataUrl, name) {
    return new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error(`"${name}" is not a photo this browser can open. Save it as a JPEG or PNG and try again.`));
        image.src = dataUrl;
    });
}

function draw(source, edge, quality) {
    const scale = Math.min(1, edge / Math.max(source.naturalWidth, source.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(source.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(source.naturalHeight * scale));
    const context = canvas.getContext('2d');
    // A white ground, so a picture with transparency does not turn black as a JPEG.
    context.fillStyle = '#fff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(source, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL('image/jpeg', quality);
}

/** Redraws a photo as a JPEG no longer than 1,568 pixels on a side and small enough to send. */
async function shrink(dataUrl, name) {
    const source = await loadImage(dataUrl, name);
    let edge = LONG_EDGE;
    let quality = 0.85;
    for (let attempt = 0; attempt < SHRINK_ATTEMPTS; attempt += 1) {
        const data = draw(source, edge, quality).split(',')[1];
        if (data.length * BASE64_RATIO <= LIMITS.imageBytes) {
            return { data, thumbUrl: draw(source, THUMB_EDGE, 0.8) };
        }
        // Give up some quality first, then some size.
        if (quality > 0.6) {
            quality -= 0.1;
        } else {
            edge = Math.round(edge * 0.8);
        }
    }
    throw new Error(`"${name}" is too large to send, even after shrinking it. Try a smaller copy.`);
}

function attachment(name, mediaType, data, thumbUrl) {
    nextId += 1;
    const bytes = Math.round(data.length * BASE64_RATIO);
    const isPdf = mediaType === PDF;
    // The chip says what kind of file it is, so its name is shown without the extension.
    const displayName = name.replace(/\.[a-z0-9]{2,5}$/i, '');
    return {
        id: `file-${Date.now().toString(36)}-${nextId}`,
        name,
        displayName,
        mediaType,
        data,
        bytes,
        thumbUrl,
        isPdf,
        isImage: !isPdf,
        kindLabel: isPdf ? 'PDF' : 'Photo',
        sizeLabel: sizeLabel(bytes),
        title: `${displayName} (${isPdf ? 'PDF' : 'photo'}, ${sizeLabel(bytes)})`,
        viewLabel: `View ${displayName}`,
        removeLabel: `Remove ${displayName}`
    };
}

/**
 * Gets a file ready to send: a photo is redrawn as a JPEG, a PDF is read as it is.
 *
 * @param {{name: string, mediaType: string, dataUrl: (string|undefined), blob: (Blob|undefined), bytes: number}} source
 *   A file from this computer (blob) or one already read (dataUrl)
 * @returns {Promise<object>} The attachment, with its base64 data
 * @throws {Error} With what to tell the person when the file is the wrong kind or too large
 */
async function prepare({ name, mediaType, dataUrl, blob, bytes }) {
    if (mediaType === PDF) {
        if (bytes > LIMITS.pdfBytes) {
            throw new Error(`"${name}" is ${sizeLabel(bytes)}. A PDF can be up to ${sizeLabel(LIMITS.pdfBytes)} here.`);
        }
        const url = dataUrl ?? (await readAsDataUrl(blob, name));
        return attachment(name, PDF, url.split(',')[1]);
    }
    if (!IMAGE_TYPES.includes(mediaType)) {
        throw new Error(`"${name}" is not a photo or a PDF. Claude can read JPEG, PNG, WebP and GIF photos, and PDFs.`);
    }
    const shrunk = await shrink(dataUrl ?? (await readAsDataUrl(blob, name)), name);
    return attachment(name, 'image/jpeg', shrunk.data, shrunk.thumbUrl);
}

/** A file picked, pasted or dropped. A pasted screenshot has no name of its own. */
export function prepareFile(file) {
    const name = file.name && file.name !== 'image.png' ? file.name : 'Pasted image';
    return prepare({ name, mediaType: typeOf(file), blob: file, bytes: file.size });
}

/** A file from the open record, as AntsuranceClaudeController.getRecordFile returns it. */
export function prepareRecordFile(recordFile) {
    return prepare({
        name: recordFile.name,
        mediaType: recordFile.mediaType,
        dataUrl: `data:${recordFile.mediaType};base64,${recordFile.data}`,
        bytes: recordFile.bytes
    });
}

/**
 * What the chat keeps of a file to show it: its small picture, and for a photo the picture as it was
 * sent, to look at full size. A PDF's contents are not kept once they stop traveling with the conversation.
 */
export function forViewing({ id, name, displayName, thumbUrl, isPdf, isImage, kindLabel, sizeLabel: size, title, data }) {
    return { id, name, displayName, thumbUrl, isPdf, isImage, kindLabel, sizeLabel: size, title, previewUrl: isImage ? `data:image/jpeg;base64,${data}` : undefined };
}

/** How a set of files reads in a few words: one file by its name, several by what they are. */
export function summarize(files) {
    if (files.length === 1) {
        return files[0].displayName;
    }
    const pdfs = files.filter((file) => file.isPdf).length;
    const photos = files.length - pdfs;
    const parts = [];
    if (photos) {
        parts.push(photos === 1 ? '1 photo' : `${photos} photos`);
    }
    if (pdfs) {
        parts.push(pdfs === 1 ? '1 PDF' : `${pdfs} PDFs`);
    }
    return parts.join(', ');
}

/** How a message names a file in the conversation. The file itself travels beside it. */
export function toReference({ id, name, mediaType }) {
    return { type: 'attachment', id, name, media_type: mediaType };
}
