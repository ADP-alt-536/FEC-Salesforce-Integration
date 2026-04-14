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
 *   Database.executeBatch(new FECDataSyncBatch(2024), 5);
 *
 * Batch size is kept small (default 5) because each record triggers multiple
 * HTTP callouts and Salesforce allows at most 100 callouts per transaction.
 */
public with sharing class FECDataSyncBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts {

    private Integer cycle;
    private Integer batchSize;

    /** Default constructor uses the current election cycle. */
    public FECDataSyncBatch() {
        this(currentCycle(), 5);
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
        this(cycle, 5);
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
        FECAPIService         apiSvc  = new FECAPIService();
        FECCommitteeSync      commSvc = new FECCommitteeSync(apiSvc);
        FECPACContributionSync pacSvc = new FECPACContributionSync(apiSvc, commSvc);

        for (SObject obj : scope) {
            Legislator__c leg = (Legislator__c) obj;
            try {
                processSingleLegislator(leg, commSvc, pacSvc);
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
            FECCommitteeSync commSvc,
            FECPACContributionSync pacSvc) {

        // Step 1: Sync / create the principal campaign committee
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

        // Step 2: Sync PAC contributions received by that committee
        pacSvc.syncContributions(
            committee.FEC_Committee_ID__c,
            cycle,
            leg.Id
        );
    }

    /** Returns the current (or upcoming) election cycle year. */
    private static Integer currentCycle() {
        Integer year = Date.today().year();
        // FEC cycles are even-numbered years
        return (Math.mod(year, 2) == 0) ? year : year + 1;
    }
}
