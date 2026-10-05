/**
 * @description Demo helper for the claims assistant: attaches the sample claim documents (shipped
 * as static resources) to the demo claims they were written for, so there is something for Claude
 * to read straight after the demo data is loaded.
 *
 * Run AntsuranceClaimsAssistantDemo.attachSampleDocuments() from Anonymous Apex after
 * AntsuranceDemoData.reset(). It is safe to run more than once.
 */
public with sharing class AntsuranceClaimsAssistantDemo {
    private static final String PIPE_CLAIM = 'Burst pipe flooded finished basement';
    private static final String REAR_END_CLAIM = 'Rear-ended at a red light on Harlem Ave';
    private static final String ROOF_CLAIM = 'Installer fell from second-story roof';

    /** One sample document: where it goes, the static resource that holds it and how it is named on the claim. */
    private class SampleDocument {
        String claimSubject;
        String resourceName;
        String title;
        String extension;

        SampleDocument(String claimSubject, String resourceName, String title, String extension) {
            this.claimSubject = claimSubject;
            this.resourceName = resourceName;
            this.title = title;
            this.extension = extension;
        }
    }

    private static final List<SampleDocument> SAMPLES = new List<SampleDocument>{
        new SampleDocument(PIPE_CLAIM, 'antsuranceClaimDocMitigationInvoice', 'Mitigation invoice, Lakeshore Restoration', 'pdf'),
        new SampleDocument(PIPE_CLAIM, 'antsuranceClaimDocRebuildEstimate', 'Rebuild estimate, Northshore Renovation', 'pdf'),
        new SampleDocument(REAR_END_CLAIM, 'antsuranceClaimDocCrashReport', 'Crash report, Oak Park Police', 'pdf'),
        new SampleDocument(REAR_END_CLAIM, 'antsuranceClaimDocRepairEstimatePhoto', 'Repair estimate, phone photo', 'jpg'),
        new SampleDocument(ROOF_CLAIM, 'antsuranceClaimDocFirstReport', 'Employer\'s first report of injury, Ridgeline', 'pdf'),
        new SampleDocument(ROOF_CLAIM, 'antsuranceClaimDocHospitalBill', 'Interim hospital bill, Prairie Path Medical Center', 'pdf')
    };

    /**
     * @description Attaches each sample document to its demo claim, found by the claim's subject.
     * A document already on its claim is left alone, so running this twice adds nothing.
     * @return A line saying how many documents were attached and how many were already there
     */
    public static String attachSampleDocuments() {
        Set<String> subjects = new Set<String>();
        Set<String> resourceNames = new Set<String>();
        for (SampleDocument sample : SAMPLES) {
            subjects.add(sample.claimSubject);
            resourceNames.add(sample.resourceName);
        }
        Map<String, Id> claimIds = new Map<String, Id>();
        for (Case claim : [SELECT Subject FROM Case WHERE Subject IN :subjects AND RecordType.DeveloperName = 'Claim' ORDER BY CreatedDate DESC]) {
            claimIds.put(claim.Subject, claim.Id);
        }
        Map<String, Blob> bodies = new Map<String, Blob>();
        for (StaticResource resource : [SELECT Name, Body FROM StaticResource WHERE Name IN :resourceNames]) {
            bodies.put(resource.Name, resource.Body);
        }
        // Titles already on each claim, so nothing is attached twice.
        Set<String> present = new Set<String>();
        if (!claimIds.isEmpty()) {
            for (ContentDocumentLink link : [SELECT LinkedEntityId, ContentDocument.Title FROM ContentDocumentLink WHERE LinkedEntityId IN :claimIds.values()]) {
                present.add(link.LinkedEntityId + '|' + link.ContentDocument.Title);
            }
        }

        List<ContentVersion> versions = new List<ContentVersion>();
        Integer skipped = 0;
        Integer missing = 0;
        for (SampleDocument sample : SAMPLES) {
            Id claimId = claimIds.get(sample.claimSubject);
            Blob body = bodies.get(sample.resourceName);
            if (claimId == null || body == null) {
                missing++;
            } else if (present.contains(claimId + '|' + sample.title)) {
                skipped++;
            } else {
                versions.add(
                    new ContentVersion(
                        Title = sample.title,
                        PathOnClient = sample.title + '.' + sample.extension,
                        VersionData = body,
                        FirstPublishLocationId = claimId
                    )
                );
            }
        }
        insert versions;
        return versions.size() +
            ' attached, ' +
            skipped +
            ' already there' +
            (missing == 0 ? '.' : ', ' + missing + ' skipped because the claim or the file was not found.');
    }
}
