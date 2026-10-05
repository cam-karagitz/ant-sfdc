import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import getPhotos from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.getPhotos';
import getMarks from '@salesforce/apex/AntsuranceClaimsAssistantFocus.getMarks';
import saveAreas from '@salesforce/apex/AntsuranceClaimsAssistantFocus.saveAreas';
import askAboutAreas from '@salesforce/apex/AntsuranceClaimsAssistantFocus.askAboutAreas';
import moveBox from '@salesforce/apex/AntsuranceClaimsAssistantFocus.moveBox';
import dismissFinding from '@salesforce/apex/AntsuranceClaimsAssistantFocus.dismissFinding';
import undoCorrection from '@salesforce/apex/AntsuranceClaimsAssistantFocus.undoCorrection';
import photoData from '@salesforce/apex/AntsuranceClaimsAssistantFocus.photoData';
import { cropToJpeg } from 'c/antsuranceImageMarker';
import { pageOf } from 'c/antsuranceUiMemory';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';

const SEVERITIES = {
    minor: { label: 'Minor', rank: 1 },
    moderate: { label: 'Moderate', rank: 2 },
    severe: { label: 'Severe', rank: 3 }
};
// What Claude can say about an area a person marked, beyond the three severities of damage.
const AREA_CHIPS = {
    none: { label: 'No damage seen', className: 'c-chip c-chip_clear' },
    unclear: { label: 'Cannot tell', className: 'c-chip c-chip_quiet' }
};
const FITS = {
    fits: 'Fits the reported loss.',
    check: 'Something to check against the reported loss.',
    unclear: 'Cannot tell whether it fits the reported loss.'
};
// The same verdict on every finding in a photo, said once above the list.
const SHARED_FITS = {
    fits: 'These all fit the reported loss.',
    check: 'Each of these is something to check against the reported loss.',
    unclear: 'Claude cannot tell whether these fit the reported loss.'
};
// A close-up shows the area with this much of its surroundings on each side.
const ZOOM_PAD = 0.15;
const LETTERS = 'ABCDEFGH';
const FALLBACK_ERROR = 'The photos could not be loaded.';
const SAVE_ERROR = 'That change could not be saved. The photo shows what is stored.';
const ASK_ERROR = 'Claude could not be asked. Try again.';
// A change is saved once the person pauses, so a drag or a run of key presses is one save.
const SAVE_DELAY_MS = 600;
const CROP_EDGE = 640;
// A list beside the photo shows this many rows at a time; the rest are a page away.
const PAGE_SIZE = 5;

const clone = (value) => JSON.parse(JSON.stringify(value));

// A title somebody wrote reads as words. A file or camera name (IMG_2041, antsuranceDamageRearQuarter) does not.
const isWritten = (title) => /\s/.test(title ?? '') && !/^(img|dsc|pxl|image|photo|screenshot)[\s_-]*\d/i.test(title);

/** "No, the rear door shows no dents" reads as a reply to a question the page does not show: start at what was found. */
function startWithWhatWasFound(text) {
    const said = (text ?? '').replace(/^(yes|no)\s*[,.:;]\s+/i, '');
    return said.charAt(0).toUpperCase() + said.slice(1);
}

function loadImage(address) {
    return new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error('The photo could not be opened.'));
        image.src = address;
    });
}

/**
 * A claim's photographs, with what Claude saw in them and what people marked on them.
 *
 * Full: one photo at a time in a carousel (arrows, a count, thumbnails, and the left and right arrow
 * keys while the carousel has the keyboard), with Claude's boxes drawn over the damage. Beside it,
 * or beneath it when there is no room, the section chosen in the tabs above. "Findings" is one list:
 * what Claude found, numbered as its boxes are, then the areas people marked, lettered from A and
 * named as theirs. Each row says what it is, how severe, what Claude saw and whether it fits the
 * reported loss. Choosing a row rings its box and lets the others step back; choosing a box opens
 * its row; hovering either does the same lightly. The open row offers a close-up of its area. The
 * list shows five rows at a time, so the viewer keeps its height however much there is.
 * "Mark an area" lets a person draw boxes of their own, add a note to each and ask Claude about just
 * those areas. In the same mode Claude's own boxes can be moved, resized or dismissed, and the change
 * is kept under the person's name. Compact: the thumbnails alone, each with a chip for the worst
 * damage in it.
 *
 * A parent can add a tab before and a tab after the viewer's own: set `leadTab` and `tailTab` to
 * their labels and put the content in the slots named `lead` and `tail`.
 *
 * The tabs, carousel and pager are the shared ones (`c-antsurance-tabs`, `c-antsurance-carousel`,
 * `c-antsurance-step-pager`). The rows of the list are its own: each is tied to a box on the photo,
 * which the shared folding section has no way to show.
 *
 * Give it a claim Id and it loads the claim's photos and stored assessment itself. A parent that
 * already holds them can pass them as `view` instead and that request is not made. `fileIds` narrows
 * it to some of the claim's files. It fires `photoselect` when a photo is chosen, `markingchange`
 * (`{ marking, hasAreas }`) when marking starts or stops or the claim gains or loses its marked
 * areas, and `markssaved` after a marked area, an answer or a correction is stored, so a parent
 * showing the assessment can load it again.
 */
export default class AntsuranceClaimPhotoViewer extends NavigationMixin(LightningElement) {
    /** The claim. */
    @api recordId;
    /** Thumbnails with severity chips only. */
    @api compact = false;
    /** The label of a tab the parent fills through the slot named `lead`, shown first. */
    @api leadTab;
    /** The label of a tab the parent fills through the slot named `tail`, shown last. */
    @api tailTab;
    /**
     * For a report: the photo with its boxes and the findings beside it, with no tabs and nothing to
     * mark, ask or dismiss. The Photos card on the claim is the one place where photos are worked on.
     */
    @api flat = false;

    loaded;
    supplied;
    wanted;
    errorMessage;
    selectedId;
    /** Videos the browser could not play, by document id. */
    unplayable = [];
    /** Videos a person has pressed play on: each has its player in its slide from then on. */
    playing = [];
    showBoxes = true;

    // What AntsuranceClaimsAssistantFocus.getMarks returns: people's areas, Claude's findings as they stand, what was dismissed.
    marks;
    marking = false;
    chosenBox;
    activeTab;
    // The box the pointer or the keyboard is on, in the photo or in the list: brought forward lightly.
    hoverBox;
    // Whether the open finding shows a close-up of its area.
    zoomed = false;
    findsPage = 0;
    shownId;
    shownBox;
    // Each photo's width over its height, known once it has loaded: a close-up needs it.
    ratios = {};
    markError;
    asking = false;
    askingIds = [];
    askError;
    // Counts changes made here, so an answer from the server that is already out of date is not shown over them.
    version = 0;
    queue = Promise.resolve();
    timers = new Map();
    images = new Map();
    assessedKey;
    hadAreas = false;

    /** What AntsuranceClaimsAssistantPhotos.getPhotos returns, when the parent already has it. */
    @api
    get view() {
        return this.supplied ?? this.loaded;
    }
    set view(value) {
        this.supplied = value;
        this.noteAssessment();
    }

    /** ContentDocument Ids to show, as an array or a comma-separated string. All the claim's photos when empty. */
    @api
    get fileIds() {
        return this.wanted;
    }
    set fileIds(value) {
        const ids = Array.isArray(value) ? value : typeof value === 'string' ? value.split(',') : [];
        this.wanted = ids.map((id) => String(id).trim()).filter(Boolean);
    }

    /** Loads the claim's photos, assessment and marks again. */
    @api
    async refresh() {
        if (!this.recordId) {
            return;
        }
        if (!this.supplied) {
            try {
                this.loaded = await getPhotos({ caseId: this.recordId });
                this.errorMessage = undefined;
            } catch (error) {
                this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
            }
            this.assessedKey = this.keyFor(this.view);
        }
        await this.loadMarks();
    }

    /** Shows one photo large. For a parent that wants to point at a photo. */
    @api
    select(documentId) {
        this.selectedId = documentId;
    }

    connectedCallback() {
        loadBrandFonts(this);
        this.assessedKey = this.keyFor(this.view);
        this.refresh();
    }

    disconnectedCallback() {
        this.timers.forEach((timer) => clearTimeout(timer.handle));
        this.timers.clear();
    }

    keyFor(view) {
        return view ? `${view.assessment?.assessedAt ?? ''}|${view.assessment?.photos?.length ?? 0}|${view.photos?.length ?? 0}` : undefined;
    }

    /** A new assessment has boxes of its own, so what is drawn over the photos is loaded again. */
    noteAssessment() {
        const key = this.keyFor(this.view);
        if (this.isConnected && key !== this.assessedKey) {
            this.assessedKey = key;
            this.loadMarks();
        }
    }

    async loadMarks() {
        if (!this.recordId || this.isCompact) {
            return;
        }
        const stamp = this.version;
        try {
            const marks = await getMarks({ caseId: this.recordId });
            if (this.version === stamp) {
                this.marks = marks;
                this.announce();
            }
        } catch (error) {
            // The photos and Claude's boxes still show; only marking is unavailable.
            this.marks = undefined;
        }
    }

    get isCompact() {
        return this.compact === true || this.compact === 'true';
    }

    get isAssessed() {
        return Boolean(this.view?.assessment);
    }

    get me() {
        return 'you';
    }

    /** The files to show, each with what Claude made of it and what people marked on it. */
    get items() {
        const reads = new Map((this.view?.assessment?.photos ?? []).map((read) => [read.documentId, read]));
        const marked = new Map((this.marks?.photos ?? []).map((photo) => [photo.documentId, photo]));
        const wanted = this.wanted?.length ? new Set(this.wanted) : undefined;
        // Photographs of damage come first, a photo Claude could not judge (a sheet of paper, a dark shot) after them, video last.
        const place = (photo) => {
            if (photo.kind === 'video') {
                return 2;
            }
            const read = reads.get(photo.documentId);
            return read && !read.usable ? 1 : 0;
        };
        const files = (this.view?.photos ?? [])
            .filter((photo) => !wanted || wanted.has(photo.documentId))
            .map((photo, position) => ({ photo, position }))
            .sort((first, second) => place(first.photo) - place(second.photo) || first.position - second.position)
            .map((entry) => entry.photo);
        const chosen = files.some((photo) => photo.documentId === this.selectedId) ? this.selectedId : files[0]?.documentId;
        const time = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
        return files.map((photo, index) => {
            const read = reads.get(photo.documentId);
            const marksHere = marked.get(photo.documentId);
            const isVideo = photo.kind === 'video';
            const isSelected = photo.documentId === chosen;
            // Claude's own findings. With the marks loaded they come from there, which leaves out the
            // entries that repeat a person's area; without, from the assessment as it is stored.
            const found = this.marks ? (marksHere?.findings ?? []) : (read?.damage ?? []).map((area, position) => ({ ...area, index: position }));
            // When every finding carries the same verdict on the fit, it is said once above the list, not under each row.
            const sharedFit = found.length > 1 && found.every((area) => area.fits && area.fits === found[0].fits) ? found[0].fits : undefined;
            const damage = found.map((area, position) => {
                const severity = SEVERITIES[area.severity] ?? SEVERITIES.minor;
                const id = `f-${area.index}`;
                return {
                    ...area,
                    id,
                    key: `${photo.documentId}-${id}`,
                    order: position + 1,
                    detail: keepTogether(area.detail),
                    severityLabel: severity.label,
                    rank: severity.rank,
                    chipClass: `c-chip c-chip_${area.severity}`,
                    tagClass: `c-tag c-tag_${area.severity}`,
                    isPerson: false,
                    tag: String(position + 1),
                    title: area.area,
                    why: keepTogether(area.detail),
                    fitLine: sharedFit ? undefined : FITS[area.fits],
                    noBoxLine: area.box ? undefined : 'No single area: seen across the photo.',
                    chip: { label: severity.label, className: `c-chip c-chip_${area.severity}` },
                    metaLine: area.changedBy ? `Found by Claude. Box moved by ${area.changedBy}.` : 'Found by Claude.',
                    dismissLabel: `Dismiss ${area.area}`,
                    undoLabel: `Put Claude's box back on ${area.area}`
                };
            });
            const areas = (marksHere?.areas ?? []).map((area, position) => {
                const letter = LETTERS[position] ?? '?';
                const id = `a-${area.id}`;
                const answer = area.answer;
                const severity = answer ? SEVERITIES[answer.severity] : undefined;
                const chip = !answer ? undefined : severity ? { label: severity.label, className: `c-chip c-chip_${answer.severity}` } : (AREA_CHIPS[answer.severity] ?? AREA_CHIPS.unclear);
                const isAsking = this.asking && this.askingIds.includes(area.id);
                const who = area.byName ?? this.me;
                return {
                    ...area,
                    id,
                    areaId: area.id,
                    key: `${photo.documentId}-${id}`,
                    letter,
                    isPerson: true,
                    tag: letter,
                    tagClass: 'c-tag c-tag_person',
                    title: answer?.area || `Area ${letter}`,
                    by: `Marked by ${who}`,
                    who,
                    noteQuoted: area.note ? `“${area.note}”` : undefined,
                    noteValue: area.note ?? '',
                    noteLabel: `Note for area ${letter}`,
                    removeLabel: `Remove area ${letter}`,
                    rank: severity?.rank ?? 0,
                    chip,
                    isAnswered: Boolean(answer),
                    isStale: Boolean(answer?.stale),
                    isPending: !answer || Boolean(answer.stale),
                    isAsking,
                    isWaiting: !answer && !isAsking,
                    // The person's question is not shown beside the answer, so an answer does not open with Yes or No.
                    why: answer ? keepTogether(startWithWhatWasFound(answer.sees)) : isAsking ? 'Claude is looking at this area.' : area.note ? `“${area.note}”` : 'Claude has not been asked about this area yet.',
                    // Claude's own sentence on the fit says more than the bare verdict, so it is used when there is one.
                    fitLine: answer ? keepTogether(answer.fitsNote || FITS[answer.fits] || FITS.unclear) : undefined,
                    action: keepTogether(answer?.action),
                    metaLine: answer?.askedAt ? `Claude answered ${time.format(new Date(answer.askedAt))}.` : 'Marked, not asked about yet.'
                };
            });
            const dismissed = (marksHere?.dismissed ?? []).map((correction) => ({
                ...correction,
                key: `${photo.documentId}-${correction.id}`,
                line: `${correction.area}: dismissed by ${correction.byName}.`,
                undoLabel: `Put ${correction.area} back`
            }));
            const worstRank = Math.max(0, ...damage.map((area) => area.rank), ...areas.map((area) => area.rank));
            const worst = Object.keys(SEVERITIES).find((name) => SEVERITIES[name].rank === worstRank);
            let chip;
            if (isVideo) {
                chip = { label: 'Video', className: 'c-chip c-chip_quiet' };
            } else if (worst) {
                chip = { label: SEVERITIES[worst].label, className: `c-chip c-chip_${worst}` };
            } else if (!read) {
                chip = this.isAssessed ? { label: 'Not assessed', className: 'c-chip c-chip_quiet' } : undefined;
            } else if (!read.usable) {
                chip = { label: 'Not usable', className: 'c-chip c-chip_quiet' };
            } else {
                chip = { label: 'No damage seen', className: 'c-chip c-chip_clear' };
            }
            const claudeBoxes = this.showBoxes || this.marking ? damage.filter((area) => area.box) : [];
            return {
                ...photo,
                index,
                position: `Photo ${index + 1} of ${files.length}`,
                count: `${index + 1} of ${files.length}`,
                // What the photo is called on screen: its title when a person wrote one, otherwise its place.
                name: isWritten(photo.title) ? photo.title : `Photo ${index + 1}`,
                sharedFit: sharedFit ? SHARED_FITS[sharedFit] : undefined,
                isVideo,
                cannotPlay: isVideo && this.unplayable.includes(photo.documentId),
                isPlaying: isVideo && this.playing.includes(photo.documentId),
                videoLabel: isVideo ? `Video: ${photo.title}` : undefined,
                playLabel: isVideo ? `Play the video ${photo.title}` : undefined,
                videoLine: isVideo ? ['Video', photo.sizeLabel].filter(Boolean).join(', ') + '. Press play to watch it here.' : undefined,
                fileUrl: `/lightning/r/ContentDocument/${photo.documentId}/view`,
                read,
                shows: keepTogether(read?.shows),
                isUnusable: Boolean(read) && !read.usable,
                unusableLine: read && !read.usable ? `Claude could not judge damage from this photo: ${(read.unusableReason || 'it is not clear enough').toLowerCase()}.` : undefined,
                // A photo that was never sent to Claude says why; a video says so on its own tile.
                tooLargeLine: isVideo ? undefined : photo.whyNot,
                damage,
                hasDamage: damage.length > 0,
                hasClaudeBoxes: damage.some((area) => area.box),
                areas,
                hasAreas: areas.length > 0,
                finds: [...damage, ...areas],
                dismissed,
                hasDismissed: dismissed.length > 0,
                // Larger boxes are drawn first, so a small box that sits inside a large one can still be reached.
                markerBoxes: [
                    ...claudeBoxes.map((area) => ({
                        id: area.id,
                        ...area.box,
                        tag: String(area.order),
                        tone: area.severity,
                        kind: 'claude',
                        label: `${area.order}. ${area.area}, ${area.severityLabel.toLowerCase()}, found by Claude`
                    })),
                    ...areas.map((area) => ({
                        id: area.id,
                        ...area.box,
                        tag: area.letter,
                        tone: 'mark',
                        kind: 'person',
                        label: `Area ${area.letter}, marked by ${area.who}${area.isAnswered ? `: ${area.title}` : ''}`
                    }))
                ].sort((one, other) => other.width * other.height - one.width * one.height),
                chip,
                isSelected,
                isMarking: isSelected && this.marking,
                chosenBox: isSelected ? this.chosenBox : undefined,
                hoverBox: isSelected ? this.hoverBox : undefined,
                pressed: isSelected ? 'true' : 'false',
                thumbClass: isSelected ? 'c-thumb c-thumb_selected' : 'c-thumb',
                thumbLabel: `${isWritten(photo.title) ? photo.title : `Photo ${index + 1}`}${chip ? `, ${chip.label.toLowerCase()}` : ''}${areas.length ? `, ${areas.length} marked` : ''}`,
                alt: read?.shows || photo.title
            };
        });
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get hasSeveral() {
        return this.items.length > 1;
    }

    get selected() {
        return this.items.find((item) => item.isSelected);
    }

    get pageSize() {
        return PAGE_SIZE;
    }

    /** The tabs above the photo: the parent's first, then the findings, then the parent's last. */
    get tabs() {
        const list = [];
        if (this.leadTab) {
            list.push({ value: 'lead', label: this.leadTab });
        }
        list.push({ value: 'finds', label: 'Findings', count: this.finds.length || undefined });
        if (this.tailTab) {
            list.push({ value: 'tail', label: this.tailTab });
        }
        return list;
    }

    get showTabs() {
        return !this.flat;
    }

    get layoutClass() {
        return this.flat ? 'c-layout c-layout_flat' : 'c-layout';
    }

    /** What the photo shows, under it. A report says that in its own words above the photo, so it is not said twice there. */
    get showsLine() {
        return this.flat ? undefined : this.selected?.shows;
    }

    get showDismissed() {
        return !this.flat && Boolean(this.selected?.hasDismissed);
    }

    get currentTab() {
        if (this.flat) {
            return 'finds';
        }
        const list = this.tabs;
        return list.some((tab) => tab.value === this.activeTab) ? this.activeTab : list[0].value;
    }

    get tabLabel() {
        return this.tabs.find((tab) => tab.value === this.currentTab).label;
    }

    /**
     * Beside a video the panel says one thing, whichever tab is chosen: the assessment and its findings
     * are about the photographs, and left there they read as findings on the video.
     */
    get showsVideoNote() {
        return !this.flat && Boolean(this.selected?.isVideo);
    }

    get isLeadTab() {
        return this.currentTab === 'lead' && !this.showsVideoNote;
    }

    get isFindsTab() {
        return this.currentTab === 'finds' && !this.showsVideoNote;
    }

    get isTailTab() {
        return this.currentTab === 'tail' && !this.showsVideoNote;
    }

    /** What Claude found on this photo, then what people marked on it. */
    get finds() {
        return this.selected?.finds ?? [];
    }

    get hasFinds() {
        return this.finds.length > 0;
    }

    /**
     * The findings on this page. The chosen one is open: it shows whose it is, what to do about it,
     * a close-up when asked for, and its actions. The rest keep to their two lines.
     */
    get findRows() {
        const photo = this.selected;
        return pageOf(this.finds, this.findsPage, PAGE_SIZE).map((row) => {
            const isOpen = row.id === this.chosenBox;
            const isLit = row.id === this.hoverBox;
            const showZoom = isOpen && this.zoomed && Boolean(row.box);
            return {
                ...row,
                isOpen,
                expanded: isOpen ? 'true' : 'false',
                rowClass: ['c-find', isOpen ? 'c-find_open' : '', isLit && !isOpen ? 'c-find_lit' : ''].filter(Boolean).join(' '),
                canZoom: Boolean(row.box) && Boolean(this.ratios[photo.documentId]),
                zoomAction: showZoom ? 'Hide the close-up' : 'Zoom to this',
                zoomPressed: showZoom ? 'true' : 'false',
                zoomLabel: `Close-up of ${row.title}`,
                zoomStyle: showZoom ? this.zoomStyle(photo, row.box) : undefined,
                canDismiss: !row.isPerson && this.marking,
                canRemove: row.isPerson && this.marking
            };
        });
    }

    /** Shows one area of the photo, with a little around it, by placing the whole photo behind a window its shape. */
    zoomStyle(photo, box) {
        const left = Math.max(0, box.x - box.width * ZOOM_PAD);
        const top = Math.max(0, box.y - box.height * ZOOM_PAD);
        const wide = Math.min(1, box.x + box.width * (1 + ZOOM_PAD)) - left;
        const high = Math.min(1, box.y + box.height * (1 + ZOOM_PAD)) - top;
        const ratio = (wide / high) * this.ratios[photo.documentId];
        const across = wide >= 1 ? 0 : (left / (1 - wide)) * 100;
        const down = high >= 1 ? 0 : (top / (1 - high)) * 100;
        return `--c-zoom-ratio:${ratio.toFixed(4)};background-image:url("${photo.url}");background-size:${(100 / wide).toFixed(2)}% ${(100 / high).toFixed(2)}%;background-position:${across.toFixed(2)}% ${down.toFixed(2)}%`;
    }

    /** What the findings tab says when Claude has nothing to list. */
    get findsEmptyLine() {
        const photo = this.selected;
        if (!photo || photo.hasDamage) {
            return undefined;
        }
        if (photo.isVideo) {
            return 'Claude reads a video from frames sampled across it, not from boxes on one picture.';
        }
        if (!photo.read) {
            return this.isAssessed ? 'Claude has not looked at this photo. Assess the photos again to include it.' : 'Claude has not looked at these photos yet.';
        }
        if (photo.isUnusable) {
            return photo.unusableLine;
        }
        return photo.hasDismissed ? 'Every finding of Claude\'s on this photo was dismissed.' : 'Claude saw no damage in this photo.';
    }

    /** Under the list: how far to trust the boxes, and how to add to them. */
    get findsFoot() {
        if (this.marking) {
            return this.hasBoxes ? 'Boxes are approximate. Drag one to correct it.' : undefined;
        }
        if (this.flat) {
            // A report shows the photos; the Photos card is where they are worked on.
            const where = 'To mark an area or correct a box, use the Photos card on the Documents tab.';
            return this.hasBoxes ? `Boxes are approximate. ${where}` : where;
        }
        if (this.hasBoxes) {
            return 'Boxes are approximate.';
        }
        return undefined;
    }

    get hasBoxes() {
        return Boolean(this.selected?.hasClaudeBoxes);
    }

    get boxToggleLabel() {
        return this.showBoxes ? 'Hide the boxes' : 'Show the boxes';
    }

    get boxTogglePressed() {
        return this.showBoxes ? 'true' : 'false';
    }

    /** The toggle is put away while marking: every box is needed then. */
    get canToggleBoxes() {
        return this.hasBoxes && !this.marking;
    }

    get canMark() {
        return !this.flat && Boolean(this.marks) && Boolean(this.selected) && !this.selected.isVideo;
    }

    get markLabel() {
        return this.marking ? 'Done marking' : 'Mark an area';
    }

    get markPressed() {
        return this.marking ? 'true' : 'false';
    }

    get markClass() {
        return this.marking ? 'c-mark c-mark_on' : 'c-mark';
    }

    get showLegend() {
        return Boolean(this.selected?.hasAreas) && this.hasBoxes;
    }

    get pendingAreas() {
        return (this.selected?.areas ?? []).filter((area) => area.isPending);
    }

    get canAsk() {
        return !this.flat && (this.pendingAreas.length > 0 || this.asking);
    }

    get cannotAsk() {
        return this.asking || this.pendingAreas.length === 0;
    }

    get askLabel() {
        if (this.asking) {
            return 'Asking Claude';
        }
        return this.pendingAreas.length === 1 ? 'Ask Claude about this area' : 'Ask Claude about these areas';
    }

    get askNote() {
        const most = this.marks?.maxPerAsk ?? 5;
        if (this.asking) {
            return 'Claude is looking at the photo and at each area. This takes about fifteen seconds.';
        }
        if (this.pendingAreas.length > most) {
            return `Claude looks at ${most} areas at a time. Ask again for the rest.`;
        }
        return undefined;
    }

    get isBusy() {
        return this.asking ? 'true' : 'false';
    }

    renderedCallback() {
        // The row of the box just chosen is brought into view, without moving the page more than it must.
        if (this.chosenBox !== this.shownBox) {
            this.shownBox = this.chosenBox;
            if (this.chosenBox) {
                this.template.querySelector(`li[data-box="${this.chosenBox}"]`)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            }
        }
        const chosen = this.selected?.documentId;
        if (chosen === this.shownId) {
            return;
        }
        const moved = this.shownId !== undefined;
        this.shownId = chosen;
        // The carousel is brought to the chosen photo, and its thumbnail into view.
        const at = this.items.findIndex((item) => item.documentId === chosen);
        if (at >= 0 && (moved || at > 0)) {
            this.refs.carousel?.show(at);
        }
        if (moved) {
            this.template.querySelector('.c-thumb_selected')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        }
    }

    /** The marker over the photo being shown. Every photo in the carousel has one. */
    get marker() {
        const chosen = this.selected?.documentId;
        return chosen ? this.template.querySelector(`c-antsurance-image-marker[data-id="${chosen}"]`) : undefined;
    }

    handleSelect(event) {
        this.show(event.currentTarget.dataset.id);
    }

    handlePlay(event) {
        const documentId = event.currentTarget.dataset.id;
        if (!this.playing.includes(documentId)) {
            this.playing = [...this.playing, documentId];
        }
    }

    /** The browser could not play this video (a format it does not know): its slide says so and offers the file. */
    handleVideoError(event) {
        const documentId = event.currentTarget.dataset.id;
        if (!this.unplayable.includes(documentId)) {
            this.unplayable = [...this.unplayable, documentId];
        }
    }

    handleOpenFile(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__namedPage', attributes: { pageName: 'filePreview' }, state: { selectedRecordId: event.currentTarget.dataset.id } });
    }

    /** The carousel came to rest on a photo: by its arrows, the arrow keys or a swipe. */
    handleSlide(event) {
        const item = this.items[event.detail.index];
        if (item) {
            this.show(item.documentId);
        }
    }

    show(documentId) {
        if (documentId === this.selected?.documentId) {
            return;
        }
        this.selectedId = documentId;
        this.chosenBox = undefined;
        this.hoverBox = undefined;
        this.zoomed = false;
        this.findsPage = 0;
        this.askError = undefined;
        this.dispatchEvent(new CustomEvent('photoselect', { detail: { documentId } }));
    }

    handleTab(event) {
        this.activeTab = event.detail.value;
    }

    handlePage(event) {
        this.findsPage = event.detail.page;
    }

    /** A row is chosen: its box is ringed on the photo and the row opens. Choosing it again closes it. */
    handleRowChoose(event) {
        const id = event.currentTarget.dataset.box;
        this.chosenBox = this.chosenBox === id ? undefined : id;
        this.zoomed = false;
    }

    /** The pointer or the keyboard is on a row: its box comes forward a little. */
    handleRowEnter(event) {
        this.hoverBox = event.currentTarget.dataset.box;
    }

    handleRowLeave() {
        this.hoverBox = undefined;
    }

    handleBoxHover(event) {
        this.hoverBox = event.detail.id;
    }

    handleImageLoad(event) {
        const documentId = event.currentTarget.dataset.id;
        if (event.detail.height > 0 && !this.ratios[documentId]) {
            this.ratios = { ...this.ratios, [documentId]: event.detail.width / event.detail.height };
        }
    }

    handleZoom() {
        this.zoomed = !this.zoomed;
    }

    /** Turns to the tab, the page and the row that a box on the photo belongs to. */
    reveal(id) {
        const at = this.finds.findIndex((row) => row.id === id);
        if (at >= 0) {
            this.activeTab = 'finds';
            this.findsPage = Math.floor(at / PAGE_SIZE);
        }
    }

    handleToggleBoxes() {
        this.showBoxes = !this.showBoxes;
    }

    handleToggleMarking() {
        this.marking = !this.marking;
        this.markError = undefined;
        if (this.marking) {
            this.activeTab = 'finds';
        } else {
            this.chosenBox = undefined;
            this.flush();
        }
        this.announce(true);
    }

    /** Tells a parent when marking starts or stops, or the claim gains or loses its marked areas. */
    announce(always) {
        const hasAreas = (this.marks?.photos ?? []).some((photo) => (photo.areas ?? []).length > 0);
        if (always || hasAreas !== this.hadAreas) {
            this.hadAreas = hasAreas;
            this.dispatchEvent(new CustomEvent('markingchange', { detail: { marking: this.marking, hasAreas } }));
        }
    }

    /** Changes the marks held here at once, so the photo answers the hand; the save follows. */
    change(documentId, apply) {
        const marks = clone(this.marks);
        let photo = marks.photos.find((entry) => entry.documentId === documentId);
        if (!photo) {
            photo = { documentId, areas: [], findings: [], dismissed: [] };
            marks.photos.push(photo);
        }
        apply(photo);
        this.marks = marks;
        this.version++;
        this.announce();
    }

    /** Runs one save after another, and shows what the server holds unless the person has changed something since. */
    enqueue(work) {
        const run = async () => {
            const stamp = this.version;
            try {
                const marks = await work();
                if (marks && this.version === stamp && this.timers.size === 0) {
                    this.marks = marks;
                }
                this.markError = undefined;
                this.announce();
                this.dispatchEvent(new CustomEvent('markssaved'));
            } catch (error) {
                this.markError = error?.body?.message ?? SAVE_ERROR;
                this.version++;
                await this.loadMarks();
            }
        };
        this.queue = this.queue.then(run, run);
        return this.queue;
    }

    /** Saves once the person pauses. A later change to the same thing replaces the save that was waiting. */
    schedule(key, work) {
        clearTimeout(this.timers.get(key)?.handle);
        const fire = () => {
            this.timers.delete(key);
            this.enqueue(work);
        };
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timers.set(key, { fire, handle: setTimeout(fire, SAVE_DELAY_MS) });
    }

    /** Sends every save that is waiting and resolves when all of them are stored. */
    flush() {
        [...this.timers.values()].forEach((timer) => {
            clearTimeout(timer.handle);
            timer.fire();
        });
        return this.queue;
    }

    scheduleAreas(documentId) {
        this.schedule(`areas-${documentId}`, () => {
            const photo = (this.marks?.photos ?? []).find((entry) => entry.documentId === documentId);
            const areas = (photo?.areas ?? []).map((area) => ({ id: area.id, box: area.box, note: area.note }));
            return saveAreas({ caseId: this.recordId, documentId, areasJson: JSON.stringify(areas) });
        });
    }

    handleBoxAdd(event) {
        const documentId = this.selected.documentId;
        if (this.selected.areas.length >= (this.marks?.maxAreas ?? 8)) {
            this.markError = 'A photo can hold eight marked areas. Remove one to add another.';
            return;
        }
        this.markError = undefined;
        const id = `m${Date.now().toString(36)}`;
        this.change(documentId, (photo) => photo.areas.push({ id, box: event.detail.box, note: null }));
        this.chosenBox = `a-${id}`;
        this.reveal(`a-${id}`);
        this.scheduleAreas(documentId);
        this.marker?.focusBox(`a-${id}`);
    }

    handleBoxChange(event) {
        const { id, box } = event.detail;
        const documentId = this.selected.documentId;
        if (id.startsWith('a-')) {
            this.change(documentId, (photo) => {
                const area = photo.areas.find((entry) => `a-${entry.id}` === id);
                if (area) {
                    area.box = box;
                    if (area.answer) {
                        area.answer.stale = true;
                    }
                }
            });
            this.scheduleAreas(documentId);
            return;
        }
        const index = Number(id.slice(2));
        const finding = this.selected.damage.find((area) => area.index === index);
        if (!finding) {
            return;
        }
        this.change(documentId, (photo) => {
            const entry = photo.findings.find((area) => area.index === index);
            if (entry) {
                entry.claudeBox = entry.claudeBox ?? entry.box;
                entry.box = box;
                entry.changedBy = entry.changedBy ?? this.me;
            }
        });
        // The server finds the finding by its place and name, and the correction by where the box last sat.
        this.schedule(`move-${documentId}-${index}`, () =>
            moveBox({ caseId: this.recordId, documentId, index, area: finding.area, boxJson: JSON.stringify(box) })
        );
    }

    handleBoxRemove(event) {
        const id = event.detail.id;
        if (id.startsWith('a-')) {
            this.removeArea(id.slice(2));
        } else {
            this.dismiss(Number(id.slice(2)));
        }
    }

    /** A box on the photo is chosen, by a click or by the keyboard: its row opens. */
    handleBoxSelect(event) {
        this.chosenBox = event.detail.id;
        this.zoomed = false;
        this.reveal(event.detail.id);
    }

    /** Enter on a box goes to its row: to the note while marking a person's area, otherwise to the row itself. */
    handleBoxOpen(event) {
        const id = event.detail.id;
        this.chosenBox = id;
        this.reveal(id);
        const target = this.marking && id.startsWith('a-') ? `input[data-id="${id.slice(2)}"]` : `button.c-find__head[data-box="${id}"]`;
        // The row is drawn once it has opened.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.template.querySelector(target)?.focus(), 0);
    }

    handleAddBox() {
        this.marker?.addBox();
    }

    handleNote(event) {
        const areaId = event.target.dataset.id;
        const note = event.target.value;
        const documentId = this.selected.documentId;
        this.change(documentId, (photo) => {
            const area = photo.areas.find((entry) => entry.id === areaId);
            if (area) {
                area.note = note;
                if (area.answer) {
                    area.answer.stale = true;
                }
            }
        });
        this.scheduleAreas(documentId);
    }

    handleRemoveArea(event) {
        this.removeArea(event.currentTarget.dataset.id);
    }

    removeArea(areaId) {
        const documentId = this.selected.documentId;
        this.change(documentId, (photo) => {
            photo.areas = photo.areas.filter((entry) => entry.id !== areaId);
        });
        this.chosenBox = undefined;
        this.scheduleAreas(documentId);
    }

    handleDismiss(event) {
        this.dismiss(Number(event.currentTarget.dataset.index));
    }

    async dismiss(index) {
        const documentId = this.selected.documentId;
        const finding = this.selected.damage.find((area) => area.index === index);
        if (!finding) {
            return;
        }
        // A move of the same box that is still waiting goes first, so the record keeps it.
        await this.flush();
        this.chosenBox = undefined;
        this.version++;
        this.enqueue(() => dismissFinding({ caseId: this.recordId, documentId, index, area: finding.area }));
    }

    async handleUndo(event) {
        const correctionId = event.currentTarget.dataset.id;
        const documentId = this.selected.documentId;
        await this.flush();
        this.version++;
        this.enqueue(() => undoCorrection({ caseId: this.recordId, documentId, correctionId }));
    }

    /** The photograph as an image the page may read the pixels of, to cut crops from. */
    imageFor(documentId) {
        if (!this.images.has(documentId)) {
            this.images.set(
                documentId,
                photoData({ caseId: this.recordId, documentId }).then((data) => loadImage(`data:${data.mediaType};base64,${data.base64}`))
            );
        }
        return this.images.get(documentId);
    }

    /**
     * Asks Claude about the areas on this photo that have no answer yet, or whose box or note has
     * changed since. The boxes are saved first, in their own request, so a call that fails or runs
     * out of time loses nothing and can be asked again.
     */
    async handleAsk() {
        if (this.asking || !this.selected) {
            return;
        }
        const documentId = this.selected.documentId;
        this.asking = true;
        this.askError = undefined;
        await this.flush();
        const pending = this.pendingAreas.slice(0, this.marks?.maxPerAsk ?? 5);
        if (pending.length === 0 || this.markError) {
            this.asking = false;
            return;
        }
        this.askingIds = pending.map((area) => area.areaId);
        const crops = {};
        let size = this.marker?.naturalSize;
        try {
            const image = await this.imageFor(documentId);
            size = { width: image.naturalWidth, height: image.naturalHeight };
            pending.forEach((area) => {
                const crop = cropToJpeg(image, area.box, { maxEdge: CROP_EDGE, maxBytes: this.marks?.maxCropBytes });
                if (crop) {
                    crops[area.areaId] = crop;
                }
            });
        } catch (error) {
            // Without crops Claude still has the whole photo and where each area sits in it.
            this.images.delete(documentId);
            // eslint-disable-next-line no-console
            console.warn('Photo viewer: the close-up crops could not be made, so Claude is asked without them.', error?.body?.message ?? error?.message ?? error);
        }
        let step;
        try {
            step = await askAboutAreas({
                caseId: this.recordId,
                documentId,
                areaIds: this.askingIds,
                cropsJson: JSON.stringify(crops),
                imageWidth: size?.width,
                imageHeight: size?.height
            });
        } catch (error) {
            step = { ok: false, error: error?.body?.message ?? ASK_ERROR };
        }
        if (step.ok) {
            this.marks = step.view;
            this.version++;
            this.announce();
            this.dispatchEvent(new CustomEvent('markssaved'));
        } else {
            this.askError = step.error ?? ASK_ERROR;
        }
        this.asking = false;
        this.askingIds = [];
    }
}
