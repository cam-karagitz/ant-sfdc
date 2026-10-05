/**
 * @description Prints one policy document for a customer who asked for it on the portal, as the internal
 * user that files portal requests. The document is the internal org's own Visualforce page (found through
 * AntsuranceDocumentController, so it is the same page the Documents tab prints). The PDF is saved to the
 * policy's files as a file of the portal's site, its page count is noted on it, and it is shared with that
 * one customer. It is a job of its own because a page cannot be printed to PDF from inside a trigger.
 */
public without sharing class AntsurancePortalDocumentJob implements Queueable, Database.AllowsCallouts {
    private Id policyId;
    private String key;
    private Id userId;
    private String title;

    /**
     * @description A copy to print.
     * @param policyId The policy, already checked to be the customer's
     * @param key declarations or idCards
     * @param userId The portal user who asked, to share the copy with
     * @param title What the file is called
     */
    public AntsurancePortalDocumentJob(Id policyId, String key, Id userId, String title) {
        this.policyId = policyId;
        this.key = key;
        this.userId = userId;
        this.title = title;
    }

    /**
     * @description Prints, notes the page count and shares.
     * @param context The job
     */
    public void execute(QueueableContext context) {
        String url;
        for (AntsuranceDocumentController.DocumentOption option : AntsuranceDocumentController.getDocuments(policyId)) {
            if (option.key == key) {
                url = option.url;
            }
        }
        if (url == null) {
            return;
        }
        // A test cannot render a page, so it saves a stand-in for the PDF.
        Blob pdf = Test.isRunningTest() ? Blob.valueOf('PDF') : new PageReference(url).getContentAsPDF();
        Integer pages = AntsurancePortalDocuments.pagesIn(pdf);
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title.replaceAll('[^A-Za-z0-9 -]', '') + '.pdf',
            VersionData = pdf,
            FirstPublishLocationId = policyId,
            NetworkId = AntsurancePortalDocuments.site(),
            Description = AntsurancePortalDocuments.PAGES_PREFIX + (pages == null ? 1 : pages)
        );
        insert as system version;
        AntsurancePortalDocuments.share([SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id WITH SYSTEM_MODE].ContentDocumentId, userId);
    }
}
