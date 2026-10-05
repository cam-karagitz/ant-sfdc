/**
 * Prefixes a question with the record on screen so "this claim" means something to Claude.
 * Kept free of Salesforce imports so the eval runner in scripts/eval can load the same function.
 */
export function withPageContext(context, prompt) {
    if (!context) {
        return prompt;
    }
    const thing = context.objectLabel.toLowerCase();
    return (
        `[Page context: the user has the ${context.objectLabel} record "${context.name}" open ` +
        `(object ${context.objectApiName}, Id ${context.recordId}). ` +
        `"This", "here" and "this ${thing}" refer to that record.]\n\n${prompt}`
    );
}
