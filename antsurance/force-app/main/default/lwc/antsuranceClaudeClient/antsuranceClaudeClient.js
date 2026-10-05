import sendMessage from '@salesforce/apex/AntsuranceClaudeController.sendMessage';
import sendChatStep from '@salesforce/apex/AntsuranceClaudeController.sendChatStep';
import sendChatStepWithFiles from '@salesforce/apex/AntsuranceClaudeController.sendChatStepWithFiles';

export { withPageContext } from './pageContext';

// A reply is an answer, a lookup round, or a set of blocks and proposals; Apex stops asking for lookups after four.
const MAX_STEPS = 6;
const NO_ANSWER = 'Claude did not finish answering. Try again.';

/**
 * Sends a conversation to Claude and follows it through any record lookups to the answer.
 *
 * @param {object} request
 * @param {object[]} request.messages Messages API turns, ending with a user turn
 * @param {string} [request.model] A model id from getModels; blank uses the default
 * @param {function(string[]): void} [request.onProgress] Called with the SOQL run so far after each lookup round
 * @param {boolean} [request.withActions] True for a caller that draws blocks and proposal cards: Claude then also
 *   gets the open record's facts, may propose a task, a file note or a case status change, and may answer
 *   with blocks to draw (a record card, a chart, a form and so on)
 * @param {string} [request.recordId] The record on screen, used only with withActions
 * @param {string} [request.surface] 'panel' for the utility bar panel, 'page' otherwise; used only with withActions
 * @param {{id: string, mediaType: string, data: string}[]} [request.files] The photos and PDFs the conversation's
 *   latest attachment references name, base64 encoded; used only with withActions. They are sent with every
 *   step of this question and kept nowhere. A reference whose file is not here is told to Claude as a file
 *   attached earlier and no longer sent.
 * @returns {Promise<{text: (string|null), queries: string[], refused: boolean, proposals: object[], blocks: object[], conversation: (object[]|undefined)}>}
 *   text is null when the reply is only blocks or proposals. Each block is { id, kind, spec }. conversation is
 *   the full exchange to replay next time, or undefined when there is nothing to replay. Neither a proposal
 *   nor a block writes anything; see AntsuranceClaudeActions and AntsuranceClaudeDisplay.
 * @throws {Error} When a step runs out of Salesforce's callout time, the error has timedOut = true, the message
 *   to show, and what it takes to send that same step again: conversation (pass it back as messages) and the
 *   queries, proposals and blocks gathered before it. Nothing is lost; lookups already done are not repeated.
 */
export async function askClaude({ messages, model, onProgress, withActions = false, recordId, surface, files = [] }) {
    let conversation = messages;
    const queries = [];
    const proposals = [];
    const blocks = [];
    for (let step = 0; step < MAX_STEPS; step += 1) {
        const messagesJson = JSON.stringify(conversation);
        // eslint-disable-next-line no-await-in-loop
        const reply = await (withActions ? sendStep({ messagesJson, model, recordId: recordId ?? null, surface: surface ?? null }, files) : sendMessage({ messagesJson, model }));
        if (reply.timedOut) {
            const late = new Error(reply.timeoutMessage);
            late.timedOut = true;
            late.conversation = conversation;
            late.queries = queries;
            late.proposals = proposals;
            late.blocks = blocks;
            throw late;
        }
        const produced = reply.appendedJson ? JSON.parse(reply.appendedJson) : [];
        queries.push(...(reply.queries ?? []));
        proposals.push(...(reply.proposals ?? []));
        blocks.push(...(reply.blocks ?? []).map((block) => ({ id: block.id, kind: block.kind, spec: JSON.parse(block.specJson) })));
        if (reply.done) {
            return {
                text: reply.text,
                queries,
                refused: reply.refused,
                proposals,
                blocks,
                // A refusal or empty answer has nothing to replay.
                conversation: produced.length ? [...conversation, ...produced] : undefined
            };
        }
        conversation = [...conversation, ...produced];
        if (onProgress) {
            onProgress(queries);
        }
    }
    throw new Error(NO_ANSWER);
}

/** One step of the chat's conversation, with the files that travel beside it when there are any. */
function sendStep(step, files) {
    return files.length
        ? sendChatStepWithFiles({
              ...step,
              fileIds: files.map((file) => file.id),
              fileTypes: files.map((file) => file.mediaType),
              fileData: files.map((file) => file.data)
          })
        : sendChatStep(step);
}

/**
 * Adds what the user typed to a conversation. After a reply that was only proposals the conversation
 * ends on the user turn that answered Claude's tool calls, and the typed text joins that turn, since
 * the Messages API takes one user turn at a time. Files attached to the message go ahead of the
 * text as references ({type: 'attachment', id, name, media_type}); Apex puts the files in their place.
 */
export function withUserMessage(messages, text, references = []) {
    const last = messages[messages.length - 1];
    if (last?.role === 'user' && Array.isArray(last.content)) {
        return [...messages.slice(0, -1), { role: 'user', content: [...last.content, ...references, { type: 'text', text }] }];
    }
    return [...messages, { role: 'user', content: references.length ? [...references, { type: 'text', text }] : text }];
}

/** Tells Claude what the user did with earlier proposal cards, ahead of their next message. */
export function withAppNotes(notes, text) {
    return notes.length ? `[App note: ${notes.join(' ')}]\n\n${text}` : text;
}

/**
 * Rewrites what Claude was told about one of its tool calls, once the user has acted on what it
 * drew: a form they saved or cancelled. The result sits where the call was answered, so the
 * conversation replays in order.
 */
export function withToolOutcome(messages, toolUseId, outcome) {
    return messages.map((message) =>
        message.role === 'user' && Array.isArray(message.content) && message.content.some((block) => block.type === 'tool_result' && block.tool_use_id === toolUseId)
            ? { ...message, content: message.content.map((block) => (block.type === 'tool_result' && block.tool_use_id === toolUseId ? { ...block, content: outcome } : block)) }
            : message
    );
}
