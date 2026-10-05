/**
 * @description A customer's own policy documents on the portal: the declarations page and, for an auto
 * policy, the ID cards. They are the same Visualforce documents the internal org prints.
 *
 * Those pages read the policy as the running user and do not check whose policy it is, so they are never
 * granted to customers. Instead the customer asks here for a copy; this class checks the policy is theirs
 * and hands the request over (see AntsurancePortalSubmissions); an internal user then prints the PDF to
 * the policy's files, as a file of the portal's site (AntsurancePortalDocumentJob), and shares that one
 * file with the customer who asked. A file can only be shared with a portal user when it belongs to their
 * site, which is why the copy is the portal's own and not one saved from the internal Documents tab.
 * The customer reads it through Salesforce's own file download, which serves a file only to someone it is
 * shared with. A copy is reused until the policy next changes, so the org's file storage is not spent on
 * repeats.
 */
public without sharing class AntsurancePortalDocuments {
    private static final Set<String> VEHICLE_TYPES = new Set<String>{ 'Vehicle', 'Fleet' };
    private static final String DECLARATIONS = 'declarations';
    private static final String ID_CARDS = 'idCards';
    public static final String PAGES_PREFIX = 'pages:';
    @TestVisible
    private static final String UNKNOWN_DOCUMENT = 'That document is not available for this policy.';
    // "/Count" as the bytes of a PDF read in hex, and the space after it.
    private static final String COUNT_HEX = '2f436f756e74';
    private static final String SPACE_HEX = '20';

    /** One document a policy has. */
    public class Doc {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String description;
        /** True when a copy is ready for this customer to read. */
        @AuraEnabled public Boolean ready = false;
        @AuraEnabled public Id documentId;
        @AuraEnabled public Id versionId;
        @AuraEnabled public String madeText;
        @AuraEnabled public Integer pages;
        @AuraEnabled public String fileName;
        /** When a copy was asked for, to look for it with getDocument. */
        @AuraEnabled public Long sentAt;
        // Not sent to the page.
        public String title;
    }

    /**
     * @description The documents one of the customer's policies has, and which are ready to read.
     * @param policyId The policy
     * @return The documents, in the order to offer them
     */
    @AuraEnabled
    public static List<Doc> getDocuments(Id policyId) {
        return documentsFor(UserInfo.getUserId(), AntsurancePortalController.me(), policyId);
    }

    /**
     * @description Asks for a copy of one document. When a current copy is already shared with the customer it
     * comes straight back; otherwise the request is handed over and the copy follows from getDocument.
     * @param policyId The policy
     * @param key declarations or idCards
     * @return The document, ready or on its way
     */
    @AuraEnabled
    public static Doc request(Id policyId, String key) {
        Doc document = find(documentsFor(UserInfo.getUserId(), AntsurancePortalController.me(), policyId), key);
        if (!document.ready) {
            AntsurancePortalSubmissions.hand('document', JSON.serialize(new Map<String, String>{ 'policyId' => policyId, 'key' => key }));
            document.sentAt = System.currentTimeMillis();
        }
        return document;
    }

    /**
     * @description One document as it stands now, to see whether the copy that was asked for has arrived.
     * @param policyId The policy
     * @param key declarations or idCards
     * @return The document
     */
    @AuraEnabled
    public static Doc getDocument(Id policyId, String key) {
        return find(documentsFor(UserInfo.getUserId(), AntsurancePortalController.me(), policyId), key);
    }

    /**
     * @description Makes the copy a customer asked for. Called by AntsurancePortalSubmissions as the internal
     * user that files portal forms: the policy is checked against the customer who sent the request, then a
     * current copy is shared with them, or a job prints one first.
     * @param userId The portal user who asked
     * @param customer That user's customer
     * @param fieldsJson The policy and the document, as handed over
     */
    public static void make(Id userId, AntsurancePortalController.Customer customer, String fieldsJson) {
        Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(fieldsJson);
        Id policyId = (Id) String.valueOf(fields.get('policyId'));
        String key = String.valueOf(fields.get('key'));
        Doc document = find(documentsFor(userId, customer, policyId), key);
        if (document.ready) {
            return;
        }
        // A current copy made for someone else in the household is shared, not printed again.
        Datetime since = [SELECT LastModifiedDate FROM Policy__c WHERE Id = :policyId WITH SYSTEM_MODE].LastModifiedDate;
        Set<Id> onPolicy = new Set<Id>();
        for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :policyId WITH SYSTEM_MODE]) {
            onPolicy.add(link.ContentDocumentId);
        }
        if (!onPolicy.isEmpty()) {
            List<ContentVersion> current = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :onPolicy AND IsLatest = TRUE AND Title = :document.title AND NetworkId != NULL AND CreatedDate >= :since
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!current.isEmpty()) {
                share(current[0].ContentDocumentId, userId);
                return;
            }
        }
        // In a test the event's trigger does not run as a member of the portal's site, so it cannot make a file of
        // the site; the test runs the job itself instead.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new AntsurancePortalDocumentJob(policyId, key, userId, document.title));
        }
    }

    /**
     * @description Shares one file with one portal user, to view. Does nothing when it is already shared.
     * @param documentId The file
     * @param userId The portal user
     */
    public static void share(Id documentId, Id userId) {
        if ([SELECT COUNT() FROM ContentDocumentLink WHERE ContentDocumentId = :documentId AND LinkedEntityId = :userId WITH SYSTEM_MODE] == 0) {
            insert as system new ContentDocumentLink(ContentDocumentId = documentId, LinkedEntityId = userId, ShareType = 'V', Visibility = 'AllUsers');
        }
    }

    /**
     * @description The portal's site. A file shared with a customer must belong to it.
     * @return The site's Id
     */
    public static Id site() {
        Id network = Network.getNetworkId();
        return network != null ? network : [SELECT Id FROM Network WHERE Name = 'Antsurance' WITH SYSTEM_MODE LIMIT 1].Id;
    }

    /**
     * @description How many pages a PDF says it has, read from its page tree ("/Count 2"). The file is searched
     * as hex because a PDF is not text Apex can decode.
     * @param pdf The file
     * @return The number of pages, or null when it cannot be read
     */
    public static Integer pagesIn(Blob pdf) {
        String hex = EncodingUtil.convertToHex(pdf);
        Integer pages = 0;
        Integer at = hex.indexOf(COUNT_HEX);
        while (at >= 0) {
            if (Math.mod(at, 2) == 0) {
                Integer cursor = at + COUNT_HEX.length();
                while (hex.mid(cursor, 2) == SPACE_HEX) {
                    cursor += 2;
                }
                String digits = '';
                // The digits 0 to 9 are the bytes 30 to 39.
                while (digits.length() < 4 && hex.mid(cursor, 1) == '3' && hex.mid(cursor + 1, 1).isNumeric()) {
                    digits += hex.mid(cursor + 1, 1);
                    cursor += 2;
                }
                if (digits != '') {
                    pages = Math.max(pages, Integer.valueOf(digits));
                }
            }
            at = hex.indexOf(COUNT_HEX, at + 1);
        }
        return pages == 0 ? null : pages;
    }

    /** The policy's documents for one customer. Throws when the policy is not theirs. */
    private static List<Doc> documentsFor(Id userId, AntsurancePortalController.Customer customer, Id policyId) {
        Policy__c owned = AntsurancePortalController.ownedPolicy(customer, policyId);
        if (owned == null) {
            throw AntsurancePortalController.fail(AntsurancePortalController.NOT_YOURS);
        }
        Policy__c policy = [SELECT Id, Name, Line_of_Business__c, LastModifiedDate, (SELECT Id FROM Assets__r WHERE Asset_Type__c IN :VEHICLE_TYPES LIMIT 1) FROM Policy__c WHERE Id = :owned.Id WITH SYSTEM_MODE];
        List<Doc> documents = new List<Doc>();
        documents.add(option(DECLARATIONS, 'Declarations page', 'Your policy at a glance: what is covered, the limits and what you pay.', 'Declarations ' + policy.Name));
        if (policy.Line_of_Business__c != null && policy.Line_of_Business__c.contains('Auto') && !policy.Assets__r.isEmpty()) {
            documents.add(option(ID_CARDS, 'Auto ID cards', 'Proof of insurance to keep in each vehicle, two cards for each.', 'ID cards ' + policy.Name));
        }

        // The newest copy of each that is shared with this customer and was made since the policy last changed.
        // (A customer can read only the files shared with them, so that is where to look.)
        Set<Id> theirs = new Set<Id>();
        for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :userId WITH SYSTEM_MODE]) {
            theirs.add(link.ContentDocumentId);
        }
        if (theirs.isEmpty()) {
            return documents;
        }
        Set<String> titles = new Set<String>();
        for (Doc document : documents) {
            titles.add(document.title);
        }
        Map<String, ContentVersion> newest = new Map<String, ContentVersion>();
        for (ContentVersion version : [
            SELECT Id, Title, ContentDocumentId, CreatedDate, Description
            FROM ContentVersion
            WHERE ContentDocumentId IN :theirs AND IsLatest = TRUE AND Title IN :titles AND CreatedDate >= :policy.LastModifiedDate
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ]) {
            if (!newest.containsKey(version.Title)) {
                newest.put(version.Title, version);
            }
        }
        for (Doc document : documents) {
            ContentVersion version = newest.get(document.title);
            if (version == null) {
                continue;
            }
            document.documentId = version.ContentDocumentId;
            document.versionId = version.Id;
            document.madeText = AntsurancePortalController.longDate(version.CreatedDate.date());
            document.pages = version.Description != null && version.Description.startsWith(PAGES_PREFIX) ? Integer.valueOf(version.Description.removeStart(PAGES_PREFIX)) : 1;
            document.ready = true;
        }
        return documents;
    }

    private static Doc option(String key, String label, String description, String title) {
        Doc document = new Doc();
        document.key = key;
        document.label = label;
        document.description = description;
        document.title = title;
        document.fileName = title + '.pdf';
        return document;
    }

    private static Doc find(List<Doc> documents, String key) {
        for (Doc document : documents) {
            if (document.key == key) {
                return document;
            }
        }
        throw AntsurancePortalController.fail(UNKNOWN_DOCUMENT);
    }
}
