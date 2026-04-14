/**
 * FECCommitteeSync
 *
 * Synchronises FEC committee data from the OpenFEC API into FEC_Committee__c records.
 * Can be called directly or from FECDataSyncBatch.
 *
 * Key responsibilities:
 *   1. Upsert FEC_Committee__c records using FEC_Committee_ID__c as the external ID.
 *   2. Update financial summary fields (cash on hand, receipts, disbursements).
 *   3. Link the committee back to a Legislator__c if a candidateId is provided.
 */
public with sharing class FECCommitteeSync {

    private FECAPIService apiService;

    public FECCommitteeSync() {
        this.apiService = new FECAPIService();
    }

    /** Constructor that accepts an injected service (used in tests). */
    public FECCommitteeSync(FECAPIService service) {
        this.apiService = service;
    }

    // ─── Public Methods ───────────────────────────────────────────────────────

    /**
     * Fetches committee financials from the FEC API and upserts a single
     * FEC_Committee__c record.
     *
     * @param committeeId  FEC committee identifier (e.g. "C00177436")
     * @param cycle        Election cycle year (e.g. 2024)
     * @param legislatorId Salesforce Id of the linked Legislator__c (may be null)
     * @return             The upserted FEC_Committee__c record
     */
    public FEC_Committee__c syncCommittee(
            String committeeId,
            Integer cycle,
            Id legislatorId) {

        FECAPIService.CommitteeFinancials fin =
            apiService.getCommitteeFinancials(committeeId, cycle);

        FEC_Committee__c committee = buildCommitteeRecord(committeeId, fin, legislatorId);
        upsert committee FEC_Committee_ID__c;
        return committee;
    }

    /**
     * Syncs a batch of committees identified by their FEC committee IDs.
     *
     * @param committeeIds  List of FEC committee IDs
     * @param cycle         Election cycle year
     * @return              List of upserted FEC_Committee__c records
     */
    public List<FEC_Committee__c> syncCommittees(
            List<String> committeeIds,
            Integer cycle) {

        List<FEC_Committee__c> records = new List<FEC_Committee__c>();
        for (String cId : committeeIds) {
            try {
                FECAPIService.CommitteeFinancials fin =
                    apiService.getCommitteeFinancials(cId, cycle);
                records.add(buildCommitteeRecord(cId, fin, null));
            } catch (FECAPIService.FECAPIException ex) {
                // Log and continue – one committee failure should not stop the rest
                System.debug(LoggingLevel.ERROR,
                    'FECCommitteeSync.syncCommittees: error for committee '
                    + cId + ': ' + ex.getMessage());
            }
        }
        if (!records.isEmpty()) {
            upsert records FEC_Committee_ID__c;
        }
        return records;
    }

    /**
     * Syncs the principal campaign committee for a Legislator__c.
     * Updates Legislator__c.Primary_Committee__c with the linked committee.
     *
     * @param legislatorId  Salesforce Id of the Legislator__c record
     * @param candidateId   FEC candidate ID stored on Legislator__c.FEC_Candidate_ID__c
     * @param cycle         Election cycle year
     * @return              The upserted FEC_Committee__c, or null if not found
     */
    public FEC_Committee__c syncLegislatorPrimaryCommittee(
            Id legislatorId,
            String candidateId,
            Integer cycle) {

        if (String.isBlank(candidateId)) {
            return null;
        }

        String principalCommitteeId =
            apiService.getPrincipalCommitteeId(candidateId, cycle);
        if (String.isBlank(principalCommitteeId)) {
            return null;
        }

        FEC_Committee__c committee =
            syncCommittee(principalCommitteeId, cycle, legislatorId);

        // Backfill the lookup on Legislator__c
        Legislator__c leg = new Legislator__c(
            Id               = legislatorId,
            Primary_Committee__c = committee.Id
        );
        update leg;

        return committee;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    private FEC_Committee__c buildCommitteeRecord(
            String committeeId,
            FECAPIService.CommitteeFinancials fin,
            Id legislatorId) {

        FEC_Committee__c rec = new FEC_Committee__c();
        rec.FEC_Committee_ID__c = committeeId;
        rec.Last_Sync_Date__c   = Datetime.now();

        if (fin != null) {
            rec.Committee_Name__c      = fin.committeeName;
            rec.Committee_Type__c      = fin.committeeType;
            rec.Designation__c         = fin.designation;
            rec.Cash_on_Hand__c        = fin.cashOnHand;
            rec.Total_Receipts__c      = fin.totalReceipts;
            rec.Total_Disbursements__c = fin.totalDisbursements;
            rec.Cycle__c               = fin.cycle;
        }

        if (legislatorId != null) {
            rec.Legislator__c = legislatorId;
        }

        // Set the record's Name field to the committee name if available
        if (fin != null && String.isNotBlank(fin.committeeName)) {
            rec.Name = fin.committeeName;
        } else {
            rec.Name = committeeId;
        }

        return rec;
    }
}
