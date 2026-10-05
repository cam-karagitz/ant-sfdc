/**
 * @description Backs the Documents component (antsuranceDocuments): says which Antsurance documents a
 * record can produce, and saves a rendered document to the record's files. Each document is a
 * Visualforce page that prints a PDF from the live record. Everything is read and saved as the
 * running user.
 */
public with sharing class AntsuranceDocumentController {
    private static final Set<String> AUTO_LINES = new Set<String>{ 'Personal Auto', 'Commercial Auto' };
    private static final Set<String> VEHICLE_TYPES = new Set<String>{ 'Vehicle', 'Fleet' };
    private static final Set<String> LIABILITY_LINES = new Set<String>{ 'General Liability', 'Commercial Auto', 'Umbrella', 'Workers Compensation' };
    private static final String LOAD_ERROR = 'The record could not be loaded. Check that it exists and that you have access to it.';
    private static final String UNKNOWN_DOCUMENT = 'That document is not available for this record.';
    private static final String STORAGE_FULL = 'The org is out of storage, so the file was not saved. Free up space, or download the document instead.';
    private static final String SAVE_ERROR = 'The file could not be saved. Check that you can add files to this record.';
    // "/Count" and a space, as the bytes of a PDF read in hex.
    private static final String COUNT_HEX = '2f436f756e74';
    private static final String SPACE_HEX = '20';
    private static final Integer MAX_COUNT_DIGITS = 4;

    /**
     * @description One document a record can produce.
     */
    public class DocumentOption {
        /** declarations, idCards, certificate or proposal. */
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String description;
        @AuraEnabled
        public String icon;
        /** The page that prints the PDF, with the record's id. */
        @AuraEnabled
        public String url;
        /** What the file is called when it is saved, without the extension. */
        @AuraEnabled
        public String title;
        /** True for the certificate, which is made out to a holder the user can name. */
        @AuraEnabled
        public Boolean takesHolder = false;
    }

    /**
     * @description A document saved to a record's files.
     */
    public class SavedFile {
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public String title;
    }

    /**
     * @description The documents a record can produce: for a policy, its declarations, ID cards when
     * it insures vehicles and a certificate when it is liability cover; for a policy sale, a proposal
     * once it has a quote; for a customer, a certificate when liability cover is in force.
     * @param recordId A policy, a policy sale or a customer account
     * @return The documents, in the order to offer them, or none for any other record
     * @throws AuraHandledException when the record cannot be read
     */
    @AuraEnabled(cacheable=true)
    public static List<DocumentOption> getDocuments(Id recordId) {
        List<DocumentOption> documents = new List<DocumentOption>();
        Schema.SObjectType objectType = recordId?.getSObjectType();
        if (objectType == Policy__c.SObjectType) {
            List<Policy__c> policies = [
                SELECT Name, Line_of_Business__c, Account__c, (SELECT Id FROM Assets__r WHERE Asset_Type__c IN :VEHICLE_TYPES LIMIT 1)
                FROM Policy__c
                WHERE Id = :recordId
                WITH USER_MODE
                LIMIT 1
            ];
            if (policies.isEmpty()) {
                throw handled(LOAD_ERROR);
            }
            Policy__c policy = policies[0];
            documents.add(option('declarations', 'Declarations page', 'Coverages, limits, forms and premium.', 'utility:contract_doc', 'AntsuranceDecPage', recordId, 'Declarations ' + policy.Name));
            if (AUTO_LINES.contains(policy.Line_of_Business__c) && !policy.Assets__r.isEmpty()) {
                documents.add(option('idCards', 'Auto ID cards', 'Two wallet cards for each vehicle.', 'utility:identity', 'AntsuranceDocumentIdCards', recordId, 'ID cards ' + policy.Name));
            }
            if (LIABILITY_LINES.contains(policy.Line_of_Business__c) && AntsuranceDocumentCertificateController.isAvailableFor(policy.Account__c)) {
                documents.add(certificate(recordId, policy.Name));
            }
        } else if (objectType == Opportunity.SObjectType) {
            List<Opportunity> sales = [SELECT Name FROM Opportunity WHERE Id = :recordId WITH USER_MODE LIMIT 1];
            if (sales.isEmpty()) {
                throw handled(LOAD_ERROR);
            }
            if (AntsuranceDocumentProposalController.isAvailableFor(recordId)) {
                documents.add(option('proposal', 'Quote proposal', 'The quoted options, side by side.', 'utility:quote', 'AntsuranceDocumentProposal', recordId, 'Proposal ' + sales[0].Name));
            }
        } else if (objectType == Account.SObjectType) {
            List<Account> customers = [SELECT Name FROM Account WHERE Id = :recordId WITH USER_MODE LIMIT 1];
            if (customers.isEmpty()) {
                throw handled(LOAD_ERROR);
            }
            if (AntsuranceDocumentCertificateController.isAvailableFor(recordId)) {
                documents.add(certificate(recordId, customers[0].Name));
            }
        }
        return documents;
    }

    /**
     * @description How many pages one of a record's documents runs to, so the preview can be made
     * tall enough to show every page without a scroll bar of its own.
     * @param recordId The policy, policy sale or customer
     * @param key Which document, as getDocuments names it
     * @param holder For a certificate, who it is made out to; blank for the default
     * @param holderAddress For a certificate, the holder's address on one line; blank for none
     * @return The number of pages, or null when it cannot be read from the PDF
     * @throws AuraHandledException when the document is not one the record offers
     */
    @AuraEnabled(cacheable=true)
    public static Integer countPages(Id recordId, String key, String holder, String holderAddress) {
        PageReference page = pageFor(documentFor(recordId, key), holder, holderAddress);
        // A test cannot render a page, so it counts the pages of a stand-in.
        return pagesIn(Test.isRunningTest() ? Blob.valueOf('<< /Type /Pages /Count 2 /Kids [3 0 R 5 0 R] >>') : page.getContentAsPDF());
    }

    /**
     * The page count a PDF declares in its page tree ("/Count 2"). The file is searched as hex
     * because a PDF is not text Apex can decode.
     */
    @TestVisible
    private static Integer pagesIn(Blob pdf) {
        String hex = EncodingUtil.convertToHex(pdf);
        Integer pages = 0;
        Integer at = hex.indexOf(COUNT_HEX);
        while (at >= 0) {
            // A match that starts halfway through a byte is not the word.
            if (Math.mod(at, 2) == 0) {
                Integer cursor = at + COUNT_HEX.length();
                while (hex.mid(cursor, 2) == SPACE_HEX) {
                    cursor += 2;
                }
                String digits = '';
                // The digits 0 to 9 are the bytes 30 to 39.
                while (digits.length() < MAX_COUNT_DIGITS && hex.mid(cursor, 1) == '3' && hex.mid(cursor + 1, 1).isNumeric()) {
                    digits += hex.mid(cursor + 1, 1);
                    cursor += 2;
                }
                if (digits != '') {
                    // A long document nests its page tree; the root carries the largest count.
                    pages = Math.max(pages, Integer.valueOf(digits));
                }
            }
            at = hex.indexOf(COUNT_HEX, at + 1);
        }
        return pages == 0 ? null : pages;
    }

    /**
     * @description Renders one of a record's documents and saves the PDF to the record's files, owned
     * by the running user.
     * @param recordId The policy, policy sale or customer
     * @param key Which document, as getDocuments names it
     * @param holder For a certificate, who it is made out to; blank for the default
     * @param holderAddress For a certificate, the holder's address on one line; blank for none
     * @return The saved file
     * @throws AuraHandledException when the document is not one the record offers, or the file cannot be saved
     */
    @AuraEnabled
    public static SavedFile saveToFiles(Id recordId, String key, String holder, String holderAddress) {
        DocumentOption chosen = documentFor(recordId, key);
        PageReference page = pageFor(chosen, holder, holderAddress);
        if (chosen.takesHolder && String.isNotBlank(holder)) {
            chosen.title += ' for ' + holder.normalizeSpace().abbreviate(60);
        }
        // A test cannot render a page, so it saves a stand-in for the PDF.
        Blob pdf = Test.isRunningTest() ? Blob.valueOf('PDF') : page.getContentAsPDF();

        ContentVersion file = new ContentVersion(
            Title = chosen.title,
            PathOnClient = AntsuranceDocumentFormat.fileSafe(chosen.title) + '.pdf',
            VersionData = pdf,
            FirstPublishLocationId = recordId
        );
        try {
            insert as user file;
        } catch (DmlException problem) {
            throw handled(problem.getDmlType(0) == StatusCode.STORAGE_LIMIT_EXCEEDED ? STORAGE_FULL : SAVE_ERROR);
        }
        SavedFile saved = new SavedFile();
        saved.title = chosen.title;
        saved.contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id WITH USER_MODE].ContentDocumentId;
        return saved;
    }

    /** The document a record offers under this key. */
    private static DocumentOption documentFor(Id recordId, String key) {
        for (DocumentOption document : getDocuments(recordId)) {
            if (document.key == key) {
                return document;
            }
        }
        throw handled(UNKNOWN_DOCUMENT);
    }

    /** The page that prints a document, with the certificate's holder when one was given. */
    private static PageReference pageFor(DocumentOption document, String holder, String holderAddress) {
        PageReference page = new PageReference(document.url);
        if (document.takesHolder && String.isNotBlank(holder)) {
            page.getParameters().put('holder', holder);
        }
        if (document.takesHolder && String.isNotBlank(holderAddress)) {
            page.getParameters().put('holderAddress', holderAddress);
        }
        return page;
    }

    private static DocumentOption certificate(Id recordId, String name) {
        DocumentOption document = option(
            'certificate', 'Certificate of insurance', 'Liability cover for a named holder.', 'utility:ribbon', 'AntsuranceDocumentCertificate', recordId,
            'Certificate ' + name
        );
        document.takesHolder = true;
        return document;
    }

    private static DocumentOption option(String key, String label, String description, String icon, String page, Id recordId, String title) {
        DocumentOption document = new DocumentOption();
        document.key = key;
        document.label = label;
        document.description = description;
        document.icon = icon;
        document.url = '/apex/' + page + '?id=' + recordId;
        document.title = title;
        return document;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException handled = new AuraHandledException(message);
        handled.setMessage(message);
        return handled;
    }
}
