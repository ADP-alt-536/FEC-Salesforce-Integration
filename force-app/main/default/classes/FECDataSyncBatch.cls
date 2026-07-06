/**
 * FECDataSyncBatch
 *
 * Batchable Apex class that iterates over all Legislator__c records that have a
 * FEC_Candidate_ID__c populated and:
 *   1. Syncs their primary campaign committee (FEC_Committee__c) from the FEC API.
 *   2. Pulls all PAC contributions received by that committee and upserts them as
 *      PAC_Contribution__c records.
 *
 * Schedule via FECDataSyncScheduler or via Developer Console:
 *   Database.executeBatch(new FECDataSyncBatch(2024), 1);
 *
 * Batch size must be 1. Each legislator requires callouts followed by DML, and
 * Salesforce prohibits callouts after DML in the same transaction. With size 1,
 * every execute() call is its own transaction: callouts first, then DML.
 */
public with sharing class FECDataSyncBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts {

    private Integer cycle;
    private Integer batchSize;

    /**
     * Overrideable factory for creating the FECAPIService.
     * In tests, replace this with a @TestVisible override to inject a pre-configured service
     * that bypasses Custom Metadata lookup.
     */
    @TestVisible
    private FECAPIService testApiServiceOverride = null;

    /** Default constructor uses the current election cycle. */
    public FECDataSyncBatch() {
        this(currentCycle(), 1);
    }

    /**
     * @param cycle      Election cycle year to sync (e.g. 2024)
     * @param batchSize  Number of Legislator__c records per batch chunk
     */
    public FECDataSyncBatch(Integer cycle, Integer batchSize) {
        this.cycle     = cycle;
        this.batchSize = batchSize;
    }

    public FECDataSyncBatch(Integer cycle) {
        this(cycle, 1);
    }

    // ─── Batchable Interface ──────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
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
    private static Integer currentCycle() {
        Integer year = Date.today().year();
        return (Math.mod(year, 2) == 0) ? year : year + 1;
    }

    /**
     * Creates the FECAPIService to use in execute().
     * In tests, set testApiServiceOverride to inject a pre-configured service.
     */
    private FECAPIService createApiService() {
        return (testApiServiceOverride != null)
            ? testApiServiceOverride
            : new FECAPIService();
    }
}
