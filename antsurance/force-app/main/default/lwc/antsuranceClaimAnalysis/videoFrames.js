/**
 * Still frames from a video, for sending to Claude, which reads images and not video.
 *
 * framesFromMp4 reads an MP4 or MOV file's own index, hands its H.264 pictures to the browser's
 * decoder and draws a few of them, evenly spaced. It does not play the video, so it works while the
 * browser tab is in the background, where a <video> element will not load at all.
 * It returns null for a file it cannot handle (another codec, a browser without the decoder), and
 * the caller falls back to playing the video in a <video> element.
 */

const DECODE_WAIT_MS = 25000;
const QUEUE_LIMIT = 24;
const MICROSECONDS = 1000000;

function boxes(view, start, end) {
    const found = [];
    let offset = start;
    while (offset + 8 <= end) {
        let size = view.getUint32(offset);
        const type = String.fromCharCode(view.getUint8(offset + 4), view.getUint8(offset + 5), view.getUint8(offset + 6), view.getUint8(offset + 7));
        let header = 8;
        if (size === 1) {
            // A 64-bit size. Files this page handles are far smaller than 4 GB, so the low half is the size.
            size = view.getUint32(offset + 12);
            header = 16;
        } else if (size === 0) {
            size = end - offset;
        }
        if (size < header || offset + size > end) {
            break;
        }
        found.push({ type, start: offset + header, end: offset + size });
        offset += size;
    }
    return found;
}

function child(view, parent, type) {
    return boxes(view, parent.start, parent.end).find((box) => box.type === type);
}

function path(view, parent, types) {
    let box = parent;
    for (const type of types) {
        box = box && child(view, box, type);
    }
    return box;
}

function hex(value) {
    return value.toString(16).padStart(2, '0');
}

/** Reads the video track's index: where each picture is in the file, when it is shown, and how to decode it. */
function readTrack(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const moov = boxes(view, 0, bytes.byteLength).find((box) => box.type === 'moov');
    if (!moov) {
        return null;
    }
    for (const trak of boxes(view, moov.start, moov.end).filter((box) => box.type === 'trak')) {
        const mdia = child(view, trak, 'mdia');
        const hdlr = mdia && child(view, mdia, 'hdlr');
        const handler = hdlr ? String.fromCharCode(...bytes.subarray(hdlr.start + 8, hdlr.start + 12)) : '';
        const stbl = handler === 'vide' ? path(view, mdia, ['minf', 'stbl']) : undefined;
        if (!stbl) {
            continue;
        }
        const mdhd = child(view, mdia, 'mdhd');
        const timescale = mdhd ? view.getUint32(mdhd.start + (view.getUint8(mdhd.start) === 1 ? 20 : 12)) : 0;

        // The sample description: an H.264 entry (avc1 or avc3) carrying its decoder settings in avcC.
        const stsd = child(view, stbl, 'stsd');
        const entry = stsd && boxes(view, stsd.start + 8, stsd.end)[0];
        if (!entry || !timescale || (entry.type !== 'avc1' && entry.type !== 'avc3')) {
            return null;
        }
        const width = view.getUint16(entry.start + 24);
        const height = view.getUint16(entry.start + 26);
        const avcC = boxes(view, entry.start + 78, entry.end).find((box) => box.type === 'avcC');
        if (!avcC) {
            return null;
        }
        const description = bytes.slice(avcC.start, avcC.end);
        const codec = `avc1.${hex(description[1])}${hex(description[2])}${hex(description[3])}`;

        const table = (type) => child(view, stbl, type);
        const stsz = table('stsz');
        const stsc = table('stsc');
        const stco = table('stco');
        const co64 = table('co64');
        const stts = table('stts');
        if (!stsz || !stsc || !stts || (!stco && !co64)) {
            return null;
        }
        const fixedSize = view.getUint32(stsz.start + 4);
        const count = view.getUint32(stsz.start + 8);
        const sizeOf = (index) => fixedSize || view.getUint32(stsz.start + 12 + index * 4);

        const chunkCount = view.getUint32((stco || co64).start + 4);
        const chunkOffset = (index) => (stco ? view.getUint32(stco.start + 8 + index * 4) : view.getUint32(co64.start + 8 + index * 8 + 4));
        const runs = [];
        for (let index = 0, total = view.getUint32(stsc.start + 4); index < total; index++) {
            runs.push({ firstChunk: view.getUint32(stsc.start + 8 + index * 12), perChunk: view.getUint32(stsc.start + 12 + index * 12) });
        }

        const samples = [];
        let run = 0;
        for (let chunk = 0; chunk < chunkCount && samples.length < count; chunk++) {
            while (run + 1 < runs.length && chunk + 1 >= runs[run + 1].firstChunk) {
                run++;
            }
            let offset = chunkOffset(chunk);
            for (let position = 0; position < runs[run].perChunk && samples.length < count; position++) {
                const size = sizeOf(samples.length);
                samples.push({ offset, size, sync: true, decodeTime: 0, shift: 0 });
                offset += size;
            }
        }

        // When each picture is decoded (stts), how far its showing is shifted from that (ctts), and which can start a decode (stss).
        let sample = 0;
        let time = 0;
        for (let index = 0, total = view.getUint32(stts.start + 4); index < total; index++) {
            const repeat = view.getUint32(stts.start + 8 + index * 8);
            const delta = view.getUint32(stts.start + 12 + index * 8);
            for (let position = 0; position < repeat && sample < samples.length; position++) {
                samples[sample++].decodeTime = time;
                time += delta;
            }
        }
        const ctts = table('ctts');
        if (ctts) {
            sample = 0;
            for (let index = 0, total = view.getUint32(ctts.start + 4); index < total; index++) {
                const repeat = view.getUint32(ctts.start + 8 + index * 8);
                const shift = view.getInt32(ctts.start + 12 + index * 8);
                for (let position = 0; position < repeat && sample < samples.length; position++) {
                    samples[sample++].shift = shift;
                }
            }
        }
        const stss = table('stss');
        if (stss) {
            samples.forEach((entry2) => {
                entry2.sync = false;
            });
            for (let index = 0, total = view.getUint32(stss.start + 4); index < total; index++) {
                const number = view.getUint32(stss.start + 8 + index * 4);
                if (samples[number - 1]) {
                    samples[number - 1].sync = true;
                }
            }
        }
        if (!samples.length || samples.some((entry2) => entry2.offset + entry2.size > bytes.byteLength)) {
            return null;
        }
        const earliest = Math.min(...samples.map((entry2) => entry2.decodeTime + entry2.shift));
        samples.forEach((entry2) => {
            entry2.shown = ((entry2.decodeTime + entry2.shift - earliest) / timescale) * MICROSECONDS;
        });
        return { codec, description, width, height, samples, duration: (time / timescale) * MICROSECONDS };
    }
    return null;
}

/**
 * @param {Uint8Array} bytes The video file
 * @param {HTMLCanvasElement} canvas A canvas to draw on
 * @param {{count: number, longEdge: number, quality: number}} options How many frames, how large, and the JPEG quality
 * @returns {Promise<string[]|null>} JPEG frames as base64, in order; null when this file cannot be handled this way
 */
export async function framesFromMp4(bytes, canvas, { count, longEdge, quality }) {
    if (typeof VideoDecoder === 'undefined' || typeof EncodedVideoChunk === 'undefined') {
        return null;
    }
    let track;
    try {
        track = readTrack(bytes);
    } catch (error) {
        track = null;
    }
    if (!track) {
        return null;
    }
    const config = { codec: track.codec, description: track.description, codedWidth: track.width, codedHeight: track.height };
    try {
        const support = await VideoDecoder.isConfigSupported(config);
        if (!support.supported) {
            return null;
        }
    } catch (error) {
        return null;
    }

    const targets = [];
    for (let position = 0; position < count; position++) {
        targets.push((track.duration * (position + 0.5)) / count);
    }
    const frames = [];
    let failure;
    const context = canvas.getContext('2d');
    const decoder = new VideoDecoder({
        output: (frame) => {
            // Pictures arrive in the order they are shown; the first one at or after each target time is kept.
            if (frames.length < targets.length && frame.timestamp >= targets[frames.length] - 1) {
                const scale = Math.min(1, longEdge / Math.max(frame.displayWidth, frame.displayHeight, 1));
                canvas.width = Math.max(1, Math.round(frame.displayWidth * scale));
                canvas.height = Math.max(1, Math.round(frame.displayHeight * scale));
                context.drawImage(frame, 0, 0, canvas.width, canvas.height);
                frames.push(canvas.toDataURL('image/jpeg', quality).split('base64,')[1]);
            }
            frame.close();
        },
        error: (error) => {
            failure = error;
        }
    });
    decoder.configure(config);

    const deadline = Date.now() + DECODE_WAIT_MS;
    // The decoder needs every picture since the last one that can start a decode, so they all go in, in file order.
    for (const sample of track.samples) {
        if (failure || frames.length === targets.length || Date.now() > deadline) {
            break;
        }
        decoder.decode(
            new EncodedVideoChunk({ type: sample.sync ? 'key' : 'delta', timestamp: Math.round(sample.shown), data: bytes.subarray(sample.offset, sample.offset + sample.size) })
        );
        while (decoder.decodeQueueSize > QUEUE_LIMIT && !failure && Date.now() < deadline) {
            // Let the decoder catch up before giving it more.
            // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, 10));
        }
    }
    try {
        if (!failure && decoder.state === 'configured') {
            await Promise.race([
                decoder.flush(),
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                new Promise((resolve) => setTimeout(resolve, Math.max(1000, deadline - Date.now())))
            ]);
        }
    } catch (error) {
        failure = failure ?? error;
    }
    if (decoder.state !== 'closed') {
        decoder.close();
    }
    return frames.length ? frames : null;
}
