/**
 * @description Prints an approved claim letter as a US Letter PDF: /apex/AntsuranceClaimLetter?id=<File_Note__c Id>.
 * The letter is read from the file note written when it was approved, so the PDF is exactly what the
 * adjuster approved. Every line is already broken by AntsuranceClaimLetters, the same way the preview
 * beside the editor shows it. A missing or unreadable note prints a short notice, not an error.
 */
public with sharing class AntsuranceClaimLetterController {
    public Boolean found { get; private set; }
    public List<String> addressee { get; private set; }
    public String dateLine { get; private set; }
    public List<String> reference { get; private set; }
    /** False when the adjuster cleared the reference lines, so the page leaves their block out. */
    public Boolean hasReference {
        get {
            return !reference.isEmpty();
        }
    }
    public String salutation { get; private set; }
    /** Every paragraph but the last, which stays with the signature. */
    public List<AntsuranceClaimLetters.Paragraph> opening { get; private set; }
    /** The last paragraph, as a list of one or none, so the page can repeat over it. */
    public List<AntsuranceClaimLetters.Paragraph> ending { get; private set; }
    public String closing { get; private set; }
    public List<String> signer { get; private set; }
    /** What the footer calls the document, such as "Reservation of rights, claim 00002566". */
    public String documentLabel { get; private set; }
    /** The words before the page number in the footer. */
    public String pageLead { get; private set; }

    public AntsuranceClaimLetterController() {
        found = false;
        addressee = new List<String>();
        reference = new List<String>();
        signer = new List<String>();
        opening = new List<AntsuranceClaimLetters.Paragraph>();
        ending = new List<AntsuranceClaimLetters.Paragraph>();
        pageLead = 'Page ';
        documentLabel = 'Claim letter';
        String noteId = ApexPages.currentPage().getParameters().get('id');
        if (!(noteId instanceof Id)) {
            return;
        }
        List<File_Note__c> notes = [SELECT Body__c, Case__r.CaseNumber FROM File_Note__c WHERE Id = :noteId WITH USER_MODE LIMIT 1];
        if (notes.isEmpty() || !AntsuranceClaimLetters.isLetterNote(notes[0])) {
            return;
        }
        AntsuranceClaimLetters.Sheet sheet = AntsuranceClaimLetters.sheetOf(AntsuranceClaimLetters.parse(notes[0].Body__c));
        if (sheet.paragraphs.isEmpty()) {
            return;
        }
        found = true;
        addressee = sheet.addressee;
        dateLine = sheet.dateLine;
        reference = sheet.reference;
        salutation = sheet.salutation;
        closing = sheet.closing;
        signer = sheet.signer;
        ending.add(sheet.paragraphs.remove(sheet.paragraphs.size() - 1));
        opening = sheet.paragraphs;
        documentLabel = (sheet.title + (notes[0].Case__r == null ? '' : ', claim ' + notes[0].Case__r.CaseNumber)).abbreviate(60);
    }
}
