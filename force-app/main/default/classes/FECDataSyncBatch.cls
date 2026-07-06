/**
 * FECDataSyncBatch
 *
 * Batchable Apex class that iterates over Legislator__c records that have a
 * FEC_Candidate_ID__c populated and:
 *   1. Syncs their primary campaign committee (FEC_Committee__c) from the FEC API.
 *   2. Pulls all PAC contributions received by that committee and upserts them as
 *      PAC_Contribution__c records.
 *
 * Schedule via FECDataSyncScheduler or via Developer Console:
 *   Database.executeBatch(new FECDataSyncBatch(2026), 1);
 *
 * Batch size must be 1. Each legislator requires callouts followed by DML, and
 * Salesforce prohibits callouts after DML in the same transaction. With size 1,
 * every execute() call is its own transaction: callouts first, then DML.
 *
 * The optional legislatorIds parameter lets FECDataSyncScheduler pre-slice
 * legislators (using OFFSET in the schedulable context, where it is allowed)
 * and hand a specific set of Ids to each staggered batch run.
 */
public with sharing class FECDataSyncBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts {

    private Integer    cycle;
    private Integer    batchSize;
    private List<Id>   legislatorIds; // null = all legislators with FEC_Candidate_ID__c

    /**
     * Overrideable factory for creating the FECAPIService.
     * In tests, replace this with a @TestVisible override to inject a pre-configured service
     * that bypasses Custom Metadata lookup.
     */
    @TestVisible
    private FECAPIService testApiServiceOverride = null;

    public FECDataSyncBatch() {
        this(null, 1, null);
    }

    public FECDataSyncBatch(Integer cycle) {
        this(cycle, 1, null);
    }

    public FECDataSyncBatch(Integer cycle, Integer batchSize) {
        this(cycle, batchSize, null);
    }

    /**
     * @param cycle          Election cycle year (null = auto-detect)
     * @param batchSize      Records per batch chunk (must be 1)
     * @param legislatorIds  Specific legislators to process; null = all
     */
    public FECDataSyncBatch(Integer cycle, Integer batchSize, List<Id> legislatorIds) {
        this.cycle         = (cycle != null) ? cycle : currentCycle();
        this.batchSize     = batchSize;
        this.legislatorIds = legislatorIds;
    }

    // ─── Batchable Interface ──────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (legislatorIds != null && !legislatorIds.isEmpty()) {
            return Database.getQueryLocator([
                SELECT Id, FEC_Candidate_ID__c, Primary_Committee__c
                FROM Legislator__c
                WHERE Id IN :legislatorIds
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, FEC_Candidate_ID__c, Primary_Committee__c
            FROM Legislator__c
            WHERE FEC_Candidate_ID__c != null
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        FECAPIService    apiSvc  = createApiService();
        FECCommitteeSync commSvc = new FECCommitteeSync(apiSvc);

        for (SObject obj : scope) {
            Legislator__c leg = (Legislator__c) obj;
            try {
                processSingleLegislator(leg, commSvc);
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR,
                    'FECDataSyncBatch.execute: error processing legislator '
                    + leg.Id + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'FECDataSyncBatch finished. JobId=' + bc.getJobId());
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private void processSingleLegislator(
            Legislator__c leg,
            FECCommitteeSync commSvc) {

        // Step 1: Sync / create the principal campaign committee (callouts + DML)
        FEC_Committee__c committee =
            commSvc.syncLegislatorPrimaryCommittee(
                leg.Id,
                leg.FEC_Candidate_ID__c,
                cycle
            );

        if (committee == null) {
            System.debug(LoggingLevel.WARN,
                'FECDataSyncBatch: no principal committee found for legislator '
                + leg.Id + ' (candidateId=' + leg.FEC_Candidate_ID__c + ')');
            return;
        }

        // Step 2: Enqueue PAC contribution sync in its own transaction.
        // Cannot call out after the DML in step 1, so delegate to the queueable.
        // enqueueIfNotActive also acquires the chain lock (DML only, no callout).
        FECManualPACSyncQueueable.enqueueIfNotActive(
            committee.FEC_Committee_ID__c,
            cycle,
            leg.Id
        );
    }

    /**
     * Returns the current (or upcoming) election cycle year.
     * FEC cycles are even-numbered; if in an odd year the next even year is returned.
     */
    @TestVisible
    static Integer currentCycle() {
        Integer year = Date.today().year();
        return (Math.mod(year, 2) == 0) ? year : year + 1;
    }

    private FECAPIService createApiService() {
        return (testApiServiceOverride != null)
            ? testApiServiceOverride
            : new FECAPIService();
    }
}
