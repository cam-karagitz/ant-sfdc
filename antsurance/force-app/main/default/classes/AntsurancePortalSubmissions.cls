/**
 * @description Files what a customer sends from the portal: a claim, a service request, a quote to
 * confirm, or a request for a copy of a policy document.
 *
 * Why it is a hand-off and not a plain insert. Saving a claim or request runs the org's case automation
 * (follow-up tasks, the adjuster's alert, the policy's loss roll-up), and that automation reads and
 * writes policies and tasks. A portal customer is deliberately given no access to those objects, so the
 * automation cannot run as them. The portal therefore publishes an event, and the event's trigger,
 * which is configured to run as an internal user (see the PlatformEventSubscriberConfig), files the
 * record with the automation running normally.
 *
 * The event carries only the form. Whose form it is comes from the platform (the event's CreatedById),
 * never from the payload, and the form is checked again here exactly as it was before it was sent.
 */
public without sharing class AntsurancePortalSubmissions {
    /**
     * @description Hands a checked form over to be filed.
     * @param kind "claim", "driver" or "request"
     * @param fieldsJson The form's fields, by name
     */
    public static void hand(String kind, String fieldsJson) {
        Database.SaveResult result = EventBus.publish(new Antsurance_Portal_Submission__e(Kind__c = kind, Fields__c = fieldsJson));
        if (!result.isSuccess()) {
            throw AntsurancePortalController.fail('That could not be sent just now. Please try again.');
        }
    }

    /**
     * @description Files each form that was handed over. Called by the event's trigger.
     * @param submissions The events
     */
    public static void receive(List<Antsurance_Portal_Submission__e> submissions) {
        for (Antsurance_Portal_Submission__e submission : submissions) {
            try {
                file(submission.CreatedById, submission.Kind__c, submission.Fields__c);
            } catch (Exception e) {
                // The form passed these checks when it was sent, so this is unexpected. Leave a trace staff can find.
                System.debug(LoggingLevel.ERROR, 'Portal submission from user ' + submission.CreatedById + ' could not be filed: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Files one form for the customer who sent it.
     * @param userId The portal user who sent it
     * @param kind "claim", "driver", "request", "note", "withdraw", "quote", "document" or "photo"
     * @param fieldsJson The form's fields, by name
     * @return The claim or request, or null for a quote, a document or a photo, which are not cases
     */
    public static Case file(Id userId, String kind, String fieldsJson) {
        AntsurancePortalController.Customer customer = AntsurancePortalController.customerFor(userId);
        if (kind == 'note' || kind == 'withdraw') {
            return onRequest(customer, kind, fieldsJson);
        }
        // A quote becomes a policy sale with a draft quote, and a document is printed and shared: neither is a case.
        if (kind == 'quote') {
            AntsurancePortalQuote.file(customer, fieldsJson);
            return null;
        }
        if (kind == 'document') {
            AntsurancePortalDocuments.make(userId, customer, fieldsJson);
            return null;
        }
        if (kind == 'photo') {
            AntsurancePortalPhotos.attach(userId, customer, fieldsJson);
            return null;
        }
        Case record = AntsurancePortalController.build(customer, kind, fieldsJson);
        insert as system record;
        return record;
    }

    /** A note on, or the withdrawal of, one of the customer's own requests. Checked again here: whose it is, and that it is still open. */
    private static Case onRequest(AntsurancePortalController.Customer customer, String kind, String fieldsJson) {
        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(fieldsJson);
        Case request = AntsurancePortalController.ownedRequest(customer, (Id) String.valueOf(fields.get('requestId')));
        if (request.IsClosed || (kind == 'withdraw' && request.Status != 'New')) {
            return request;
        }
        String text = kind == 'withdraw' ? 'Withdrawn by the customer from the portal.' : String.valueOf(fields.get('text'));
        insert as system new File_Note__c(
            Case__c = request.Id,
            Account__c = customer.accountId,
            Policy__c = request.Policy__c,
            Note_Type__c = 'Contact',
            Author_Name__c = customer.name + ' ' + AntsurancePortalController.FROM_PORTAL,
            Note_Date__c = System.now(),
            Body__c = text
        );
        if (kind == 'withdraw') {
            update as system new Case(Id = request.Id, Status = 'Closed');
        }
        return request;
    }
}
