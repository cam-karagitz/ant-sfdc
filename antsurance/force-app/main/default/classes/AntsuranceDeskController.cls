/**
 * @description Claude's desk on Home: the work Claude prepared on its own, waiting for a person or
 * already done and reported; the decisions a person takes on it; and the setting for how much
 * Claude may do alone. AntsuranceDeskShift finds and prepares the work; this class is what the
 * page calls.
 *
 * Approving a piece does the one thing the piece is for and nothing more: it stores the brief or
 * the memo, records that the email was opened in the composer, changes the reserve, or adds the
 * follow-up task.
 */
public with sharing class AntsuranceDeskController {
    private static final String MANAGER_PERMISSION = 'Antsurance_Desk_Manager';
    private static final Integer MAX_NOTE = 255;
    private static final String ALREADY_DECIDED = 'That piece has already been decided. Refresh the desk.';
    private static final String NOT_FOUND = 'That piece is no longer on the desk.';

    /**
     * @description Everything the desk shows.
     */
    public class Desk {
        /** Pieces waiting for a person, most important first. */
        @AuraEnabled
        public List<Piece> waiting = new List<Piece>();
        /** Pieces Claude could not prepare, each with its reason and a way to try again. */
        @AuraEnabled
        public List<Piece> failed = new List<Piece>();
        /** Every piece kept, newest first: the log of what Claude did and what was decided. */
        @AuraEnabled
        public List<Piece> log = new List<Piece>();
        @AuraEnabled
        public List<Setting> settings = new List<Setting>();
        /** Whether this person may change what Claude does alone. */
        @AuraEnabled
        public Boolean canManage = false;
        @AuraEnabled
        public Datetime lastPreparedAt;
    }

    /**
     * @description One piece of prepared work.
     */
    public class Piece {
        @AuraEnabled
        public Id workId;
        @AuraEnabled
        public String kindKey;
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String status;
        /** auto or approve: the setting in force when it was prepared. */
        @AuraEnabled
        public String authority;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String reason;
        @AuraEnabled
        public String recordId;
        @AuraEnabled
        public String recordObject;
        @AuraEnabled
        public String recordName;
        /** The work itself as JSON; its shape depends on the kind. */
        @AuraEnabled
        public String work;
        @AuraEnabled
        public Datetime preparedAt;
        @AuraEnabled
        public Datetime decidedAt;
        @AuraEnabled
        public String decidedBy;
        @AuraEnabled
        public String note;
        /** True when the record has been changed since this was prepared, so the work may be out of date. */
        @AuraEnabled
        public Boolean changedSince = false;
        /** For a waiting reserve review: how many days the claim has been open, read from the claim now. What was stored when it was prepared is a day behind by morning. */
        @AuraEnabled
        public Integer daysOpen;
    }

    /**
     * @description How much Claude may do alone for one kind of work.
     */
    public class Setting {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String what;
        @AuraEnabled
        public String mode;
        @AuraEnabled
        public Boolean locked;
        @AuraEnabled
        public String lockReason;
        @AuraEnabled
        public String whenAuto;
        @AuraEnabled
        public String whenApprove;
    }

    /**
     * @description What Home says about the desk before it is opened.
     */
    public class Summary {
        @AuraEnabled
        public Integer waiting = 0;
        /** The most important waiting piece, in a line. */
        @AuraEnabled
        public String topTitle;
    }

    // ------------------------------------------------------------------ reading

    /**
     * @description The desk: what waits, the log, and the autonomy settings.
     * @return The desk for the running user
     * @throws AuraHandledException when the user cannot read prepared work
     */
    @AuraEnabled
    public static Desk getDesk() {
        try {
            return build();
        } catch (QueryException e) {
            throw error('Claude\'s desk could not be loaded. Check that you have the Antsurance Desk permission set.');
        }
    }

    /**
     * @description How many pieces wait and which matters most, for Home's tab count and briefing line.
     * Never throws: someone without access to the desk simply sees none.
     * @return The summary
     */
    public static Summary summary() {
        Summary summary = new Summary();
        try {
            // The same rows in the same order as the desk reads them, so the piece named here is the first one listed there.
            List<Claude_Work__c> rows = [
                SELECT Title__c, Kind__c
                FROM Claude_Work__c
                WHERE Status__c = :AntsuranceDeskShift.WAITING
                WITH USER_MODE
                ORDER BY Prepared_At__c DESC NULLS LAST, CreatedDate DESC
                LIMIT :AntsuranceDeskShift.KEEP
            ];
            summary.waiting = rows.size();
            for (AntsuranceDeskShift.Kind kind : byImportance()) {
                for (Claude_Work__c row : rows) {
                    if (summary.topTitle == null && AntsuranceDeskShift.kindOf(row.Kind__c).key == kind.key) {
                        summary.topTitle = row.Title__c;
                    }
                }
            }
        } catch (QueryException e) {
            summary.waiting = 0;
        }
        return summary;
    }

    private static Desk build() {
        Desk desk = new Desk();
        List<Claude_Work__c> rows = [
            SELECT
                Id, Kind__c, Status__c, Authority__c, Title__c, Reason__c, Record_Id__c, Record_Object__c, Record_Name__c, Work__c, Prepared_At__c, Record_Stamp__c,
                Importance__c, Decided_At__c, Decided_By__r.Name, Decision_Note__c
            FROM Claude_Work__c
            WITH USER_MODE
            ORDER BY Prepared_At__c DESC NULLS LAST, CreatedDate DESC
            LIMIT :AntsuranceDeskShift.KEEP
        ];
        Map<String, Datetime> modified = lastModified(rows);
        Map<Id, Case> reserved = reserveFigures(rows);
        List<Piece> waiting = new List<Piece>();
        for (Claude_Work__c row : rows) {
            Piece piece = toPiece(row);
            if (row.Status__c == AntsuranceDeskShift.WAITING) {
                Datetime now = modified.get(row.Record_Id__c);
                if (piece.kindKey == AntsuranceDeskShift.RESERVE) {
                    // A reserve review rests on two figures. Other saves to the claim, such as a new brief, do not make it out of date.
                    Case claim = reserved.get((Id) row.Record_Id__c);
                    piece.changedSince = figuresMoved(claim, row.Work__c);
                    piece.daysOpen = claim?.Days_Open__c?.intValue();
                } else {
                    // A record that is gone, or saved since, means the work may no longer fit it.
                    piece.changedSince = now == null || (row.Record_Stamp__c != null && now > row.Record_Stamp__c);
                }
                waiting.add(piece);
            } else if (row.Status__c == AntsuranceDeskShift.FAILED) {
                desk.failed.add(piece);
            }
            desk.log.add(piece);
            if (desk.lastPreparedAt == null) {
                desk.lastPreparedAt = row.Prepared_At__c;
            }
        }
        // Most important first; the rows arrive newest first, so equal importance keeps that order.
        for (AntsuranceDeskShift.Kind kind : byImportance()) {
            for (Piece piece : waiting) {
                if (piece.kindKey == kind.key) {
                    desk.waiting.add(piece);
                }
            }
        }
        desk.settings = settings();
        desk.canManage = FeatureManagement.checkPermission(MANAGER_PERMISSION);
        return desk;
    }

    private static List<AntsuranceDeskShift.Kind> byImportance() {
        List<AntsuranceDeskShift.Kind> ordered = new List<AntsuranceDeskShift.Kind>();
        for (AntsuranceDeskShift.Kind kind : AntsuranceDeskShift.allKinds()) {
            Integer at = 0;
            while (at < ordered.size() && ordered[at].importance >= kind.importance) {
                at++;
            }
            if (at == ordered.size()) {
                ordered.add(kind);
            } else {
                ordered.add(at, kind);
            }
        }
        return ordered;
    }

    /** The reserve and estimate now on each claim that has a reserve review waiting, and how long it has been open. */
    private static Map<Id, Case> reserveFigures(List<Claude_Work__c> rows) {
        Set<Id> claimIds = new Set<Id>();
        for (Claude_Work__c row : rows) {
            if (row.Status__c == AntsuranceDeskShift.WAITING && row.Kind__c == AntsuranceDeskShift.kindOf(AntsuranceDeskShift.RESERVE).label && String.isNotBlank(row.Record_Id__c)) {
                claimIds.add((Id) row.Record_Id__c);
            }
        }
        return claimIds.isEmpty()
            ? new Map<Id, Case>()
            : new Map<Id, Case>([SELECT Id, Reserve_Amount__c, Estimated_Loss__c, IsClosed, Days_Open__c FROM Case WHERE Id IN :claimIds WITH USER_MODE]);
    }

    /** True when the claim is gone or closed, or its reserve or estimate is no longer what the review was worked from. */
    private static Boolean figuresMoved(Case claim, String workJson) {
        if (claim == null || claim.IsClosed) {
            return true;
        }
        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(workJson);
        Decimal reserve = claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c;
        Decimal estimate = claim.Estimated_Loss__c == null ? 0 : claim.Estimated_Loss__c;
        return reserve != AntsuranceAiClient.toDecimal(work.get('oldReserve')) || estimate != AntsuranceAiClient.toDecimal(work.get('estimate'));
    }

    /** When each waiting piece's record was last saved, by record Id. */
    private static Map<String, Datetime> lastModified(List<Claude_Work__c> rows) {
        Map<String, Set<Id>> byObject = new Map<String, Set<Id>>();
        for (Claude_Work__c row : rows) {
            if (row.Status__c != AntsuranceDeskShift.WAITING || String.isBlank(row.Record_Id__c)) {
                continue;
            }
            if (!byObject.containsKey(row.Record_Object__c)) {
                byObject.put(row.Record_Object__c, new Set<Id>());
            }
            byObject.get(row.Record_Object__c).add((Id) row.Record_Id__c);
        }
        Map<String, Datetime> modified = new Map<String, Datetime>();
        List<SObject> records = new List<SObject>();
        if (byObject.containsKey('Case')) {
            records.addAll([SELECT Id, LastModifiedDate FROM Case WHERE Id IN :byObject.get('Case') WITH USER_MODE]);
        }
        if (byObject.containsKey('Quote')) {
            records.addAll([SELECT Id, LastModifiedDate FROM Quote WHERE Id IN :byObject.get('Quote') WITH USER_MODE]);
        }
        if (byObject.containsKey('Policy__c')) {
            records.addAll([SELECT Id, LastModifiedDate FROM Policy__c WHERE Id IN :byObject.get('Policy__c') WITH USER_MODE]);
        }
        if (byObject.containsKey('Opportunity')) {
            records.addAll([SELECT Id, LastModifiedDate FROM Opportunity WHERE Id IN :byObject.get('Opportunity') WITH USER_MODE]);
        }
        for (SObject record : records) {
            modified.put((String) record.Id, (Datetime) record.get('LastModifiedDate'));
        }
        return modified;
    }

    private static Piece toPiece(Claude_Work__c row) {
        Piece piece = new Piece();
        piece.workId = row.Id;
        piece.kind = row.Kind__c;
        piece.kindKey = AntsuranceDeskShift.kindOf(row.Kind__c).key;
        piece.status = row.Status__c;
        piece.authority = row.Authority__c;
        piece.title = row.Title__c;
        piece.reason = row.Reason__c;
        piece.recordId = row.Record_Id__c;
        piece.recordObject = row.Record_Object__c;
        piece.recordName = row.Record_Name__c;
        piece.work = row.Work__c;
        piece.preparedAt = row.Prepared_At__c;
        piece.decidedAt = row.Decided_At__c;
        piece.decidedBy = row.Decided_By__r?.Name;
        piece.note = row.Decision_Note__c;
        return piece;
    }

    private static List<Setting> settings() {
        List<Setting> settings = new List<Setting>();
        for (AntsuranceDeskShift.Kind kind : AntsuranceDeskShift.allKinds()) {
            Setting setting = new Setting();
            setting.key = kind.key;
            setting.label = kind.label;
            setting.what = kind.what;
            setting.mode = AntsuranceDeskShift.modeOf(kind);
            setting.locked = kind.locked;
            setting.lockReason = kind.lockReason;
            setting.whenAuto = kind.whenAuto;
            setting.whenApprove = kind.whenApprove;
            settings.add(setting);
        }
        return settings;
    }

    // ------------------------------------------------------------------ the shift

    /**
     * @description What a shift would prepare now. Claude is not called and nothing changes.
     * @return The plan
     * @throws AuraHandledException when the book cannot be read
     */
    @AuraEnabled
    public static AntsuranceDeskShift.Plan planShift() {
        try {
            return AntsuranceDeskShift.plan();
        } catch (QueryException e) {
            throw error('The shift could not be planned. Check your access to claims, policies and quotes.');
        }
    }

    /**
     * @description Prepares one piece of a shift. The page calls this once for each piece: one request,
     * one call to Claude, so each stays well inside Salesforce's two minutes of callout time and the
     * page can show progress. A piece that cannot be prepared (Claude timed out or could not be
     * reached) is kept on the desk as "Could not be prepared" with the reason, and returned, so the
     * shift moves on and the person can try that piece again.
     * @param kind The kind of work, by key
     * @param recordId The record it is for
     * @param recordName What the record is called, as the plan named it
     * @return The piece as kept on the desk: prepared, or recorded as not prepared
     * @throws AuraHandledException when the outcome cannot be kept on the desk at all
     */
    @AuraEnabled
    public static Piece preparePiece(String kind, Id recordId, String recordName) {
        try {
            return toPiece(reload(AntsuranceDeskShift.prepare(kind, recordId).Id));
        } catch (AntsuranceDeskShift.DeskException e) {
            if (!e.worthRetrying) {
                // Not Claude's doing: the kind is switched off, or the record no longer calls for the work.
                throw error(e.getMessage());
            }
            return noteFailure(kind, recordId, recordName, e.getMessage());
        }
    }

    /**
     * @description Records a piece the page could not get prepared at all, such as a request that
     * Salesforce ended before Claude answered. The desk then lists it with the others to try again.
     * @param kind The kind of work, by key
     * @param recordId The record it was for
     * @param recordName What the record is called
     * @param reason Why, as the page understood it
     * @return The recorded failure
     */
    @AuraEnabled
    public static Piece noteFailure(String kind, Id recordId, String recordName, String reason) {
        try {
            return toPiece(reload(AntsuranceDeskShift.recordFailure(kind, recordId, recordName, reason).Id));
        } catch (DmlException e) {
            throw error('That piece could not be prepared, and the desk could not record it: ' + e.getDmlMessage(0));
        } catch (AntsuranceDeskShift.DeskException e) {
            throw error(e.getMessage());
        }
    }

    /**
     * @description Tries again to prepare one piece that could not be prepared.
     * @param workId The row that records the failure
     * @return The desk afterwards: the piece prepared, or still listed with the latest reason
     * @throws AuraHandledException when the row is not a failed piece
     */
    @AuraEnabled
    public static Desk tryAgain(Id workId) {
        Claude_Work__c row = failedRow(workId);
        try {
            // Claude is called before anything is saved. When it works, the failure row is cleared with the new piece.
            AntsuranceDeskShift.prepare(AntsuranceDeskShift.kindOf(row.Kind__c).key, (Id) row.Record_Id__c);
        } catch (AntsuranceDeskShift.DeskException e) {
            update as user new Claude_Work__c(Id = row.Id, Reason__c = e.getMessage().abbreviate(MAX_NOTE), Prepared_At__c = Datetime.now());
        }
        return getDesk();
    }

    /**
     * @description Removes the note that a piece could not be prepared. The next shift looks at the record afresh.
     * @param workId The row that records the failure
     * @return The desk afterwards
     * @throws AuraHandledException when the row is not a failed piece
     */
    @AuraEnabled
    public static Desk discard(Id workId) {
        delete as user failedRow(workId);
        return getDesk();
    }

    private static Claude_Work__c failedRow(Id workId) {
        Claude_Work__c row;
        try {
            row = reload(workId);
        } catch (QueryException e) {
            throw error(NOT_FOUND);
        }
        if (row.Status__c != AntsuranceDeskShift.FAILED) {
            throw error('That piece is not waiting to be tried again. Refresh the desk.');
        }
        return row;
    }

    /**
     * @description Prepares a waiting piece again because its record has changed, and retires the old one.
     * @param workId The waiting piece
     * @return The desk afterwards
     * @throws AuraHandledException when the piece is not waiting or cannot be prepared again
     */
    @AuraEnabled
    public static Desk prepareAgain(Id workId) {
        Claude_Work__c row = waitingRow(workId);
        try {
            // Claude is called before anything is saved: a callout cannot follow a save in one transaction.
            AntsuranceDeskShift.prepare(AntsuranceDeskShift.kindOf(row.Kind__c).key, (Id) row.Record_Id__c);
        } catch (AntsuranceDeskShift.DeskException e) {
            throw error(e.getMessage());
        }
        decide(row, AntsuranceDeskShift.REPLACED, 'Prepared again because the record had changed.');
        return getDesk();
    }

    // ------------------------------------------------------------------ deciding

    /**
     * @description Approves a waiting piece: does the one thing it is for, then records who approved it.
     * @param workId The waiting piece
     * @param editsJson What the person changed before approving, as JSON: subject and body for an email,
     * newReserve for a reserve, taskSubject and note for a follow-up. May be blank.
     * @return The desk afterwards
     * @throws AuraHandledException when the piece is not waiting or the change cannot be saved
     */
    @AuraEnabled
    public static Desk approve(Id workId, String editsJson) {
        Claude_Work__c row = waitingRow(workId);
        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(row.Work__c);
        Map<String, Object> edits = String.isBlank(editsJson) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(editsJson);
        String kind = AntsuranceDeskShift.kindOf(row.Kind__c).key;
        Id recordId = (Id) row.Record_Id__c;
        String note;
        try {
            if (kind == AntsuranceDeskShift.BRIEF) {
                update as user new Case(Id = recordId, Claude_Brief__c = stored(work), Claude_Brief_At__c = Datetime.now());
                note = 'Brief stored on the claim.';
            } else if (kind == AntsuranceDeskShift.MEMO) {
                update as user new Quote(Id = recordId, Underwriting_Memo__c = stored(work));
                note = 'Memo stored on the quote. The underwriter still decides.';
            } else if (kind == AntsuranceDeskShift.OUTREACH) {
                keep(work, edits, new List<String>{ 'subject', 'body' });
                note = 'Opened in the email composer. Nothing is sent until you send it.';
            } else if (kind == AntsuranceDeskShift.RESERVE) {
                note = changeReserve(recordId, work, edits);
            } else {
                keep(work, edits, new List<String>{ 'taskSubject', 'note' });
                Date due = AntsuranceDeskShift.addFollowUpTask(recordId, work);
                note = 'Task added to your list, due ' + AntsuranceDeskShift.day(due) + '.';
            }
        } catch (DmlException e) {
            throw error('That could not be saved: ' + e.getDmlMessage(0));
        }
        row.Work__c = JSON.serialize(work);
        decide(row, AntsuranceDeskShift.APPROVED, note);
        return getDesk();
    }

    /**
     * @description Dismisses a waiting piece. Nothing on its record changes.
     * @param workId The waiting piece
     * @param reason Why, in a few words
     * @return The desk afterwards
     * @throws AuraHandledException when no reason is given or the piece is not waiting
     */
    @AuraEnabled
    public static Desk dismiss(Id workId, String reason) {
        if (String.isBlank(reason)) {
            throw error('Say in a few words why, so the log shows it.');
        }
        decide(waitingRow(workId), AntsuranceDeskShift.DISMISSED, reason.trim().abbreviate(MAX_NOTE));
        return getDesk();
    }

    private static String stored(Map<String, Object> work) {
        String stored = (String) work.get('stored');
        if (String.isBlank(stored)) {
            throw error('This piece has nothing left to store. Open the record and write it there.');
        }
        return stored;
    }

    /** Copies the fields a person may edit before approving from their edits into the work. */
    private static void keep(Map<String, Object> work, Map<String, Object> edits, List<String> fields) {
        for (String field : fields) {
            if (edits.get(field) instanceof String && String.isNotBlank((String) edits.get(field))) {
                work.put(field, ((String) edits.get(field)).trim());
            }
        }
    }

    private static String changeReserve(Id caseId, Map<String, Object> work, Map<String, Object> edits) {
        Decimal amount = AntsuranceAiClient.toDecimal(edits.containsKey('newReserve') ? edits.get('newReserve') : work.get('newReserve'));
        if (amount == null || amount <= 0) {
            throw error('Enter the new reserve as a figure above zero.');
        }
        amount = amount.setScale(0, System.RoundingMode.HALF_UP);
        Case claim = [SELECT Reserve_Amount__c, Paid_Amount__c FROM Case WHERE Id = :caseId WITH USER_MODE];
        if (claim.Paid_Amount__c != null && amount < claim.Paid_Amount__c) {
            throw error('The reserve cannot be below the ' + AntsuranceDeskShift.money(claim.Paid_Amount__c) + ' already paid.');
        }
        update as user new Case(Id = caseId, Reserve_Amount__c = amount);
        work.put('newReserve', amount);
        return 'Reserve changed from ' + AntsuranceDeskShift.money(claim.Reserve_Amount__c) + ' to ' + AntsuranceDeskShift.money(amount) + '.';
    }

    private static Claude_Work__c waitingRow(Id workId) {
        Claude_Work__c row;
        try {
            row = reload(workId);
        } catch (QueryException e) {
            throw error(NOT_FOUND);
        }
        if (row.Status__c != AntsuranceDeskShift.WAITING) {
            throw error(ALREADY_DECIDED);
        }
        return row;
    }

    private static Claude_Work__c reload(Id workId) {
        return [
            SELECT
                Id, Kind__c, Status__c, Authority__c, Title__c, Reason__c, Record_Id__c, Record_Object__c, Record_Name__c, Work__c, Prepared_At__c, Record_Stamp__c,
                Importance__c, Decided_At__c, Decided_By__r.Name, Decision_Note__c
            FROM Claude_Work__c
            WHERE Id = :workId
            WITH USER_MODE
        ];
    }

    private static void decide(Claude_Work__c row, String status, String note) {
        try {
            update as user new Claude_Work__c(
                Id = row.Id,
                Status__c = status,
                Work__c = row.Work__c,
                Decision_Note__c = note,
                Decided_By__c = UserInfo.getUserId(),
                Decided_At__c = Datetime.now()
            );
        } catch (DmlException e) {
            throw error('The decision could not be recorded: ' + e.getDmlMessage(0));
        }
    }

    // ------------------------------------------------------------------ what Claude may do

    /**
     * @description Sets how much Claude may do alone for each kind of work. Work that moves money or
     * goes to a customer cannot be set to auto.
     * @param modesJson Kind keys to auto, approve or off, as JSON
     * @return The desk afterwards
     * @throws AuraHandledException when the person may not change this, or a value is not allowed
     */
    @AuraEnabled
    public static Desk saveAutonomy(String modesJson) {
        if (!FeatureManagement.checkPermission(MANAGER_PERMISSION)) {
            throw error('Only a desk manager can change what Claude may do.');
        }
        Map<String, Object> modes = (Map<String, Object>) JSON.deserializeUntyped(modesJson);
        Claude_Autonomy__c setting = Claude_Autonomy__c.getOrgDefaults();
        if (setting.Id == null) {
            setting.SetupOwnerId = UserInfo.getOrganizationId();
        }
        for (AntsuranceDeskShift.Kind kind : AntsuranceDeskShift.allKinds()) {
            if (!modes.containsKey(kind.key)) {
                continue;
            }
            String mode = String.valueOf(modes.get(kind.key));
            if (mode != AntsuranceDeskShift.AUTO && mode != AntsuranceDeskShift.APPROVE && mode != AntsuranceDeskShift.OFF) {
                throw error('Choose one of the three settings for ' + kind.label + '.');
            }
            if (kind.locked && mode == AntsuranceDeskShift.AUTO) {
                throw error(kind.label + ' cannot be left to Claude alone. ' + kind.lockReason);
            }
            setting.put(kind.setting, mode);
        }
        // The setting is the org's, not the person's record, so it is saved whatever their object access; the permission check above is the gate.
        upsert setting;
        return getDesk();
    }

    private static AuraHandledException error(String message) {
        AuraHandledException problem = new AuraHandledException(message);
        problem.setMessage(message);
        return problem;
    }
}
