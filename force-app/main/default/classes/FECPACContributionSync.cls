/**
 * FECPACContributionSync
 *
 * Synchronises PAC contribution data (FEC Schedule A) from the OpenFEC API
 * into PAC_Contribution__c records.
 *
 * Only committee-origin contributions are synced, ensuring we track
 * PAC-to-candidate money flows rather than individual donations.
 *
 * Flow:
 *   1. Query Schedule A contributions for a recipient committee from the FEC API.
 *   2. Ensure both contributor and recipient FEC_Committee__c records exist.
 *   3. Upsert PAC_Contribution__c records using Transaction_ID__c as the external ID.
 *   4. Link Contributing_Account__c by contributor FEC id:
 *      - Primary: Account.FEC_ID__c = contributor committee FEC id
 *      - Fallback: Account.Corporate_PAC_Committee__c lookup mapping
 */
public with sharing class FECPACContributionSync {

    private FECAPIService    apiService;
    private FECCommitteeSync committeeSync;

    public FECPACContributionSync() {
        this.apiService    = new FECAPIService();
        this.committeeSync = new FECCommitteeSync(apiService);
    }

    /** Injectable constructor for testing. */
    public FECPACContributionSync(FECAPIService svc, FECCommitteeSync cs) {
        this.apiService    = svc;
        this.committeeSync = cs;
    }

    // ─── Public Methods ───────────────────────────────────────────────────────

    /**
     * Fetches all PAC contributions received by the given committee for the
     * specified cycle and upserts them into PAC_Contribution__c.
     *
     * @param recipientCommitteeId  FEC committee ID of the recipient
     * @param cycle                 Election cycle year (e.g. 2024)
     * @param recipientLegislatorId Salesforce Id of the linked Legislator__c (may be null)
     * @return                      List of upserted PAC_Contribution__c records
     */
    public List<PAC_Contribution__c> syncContributions(
            String recipientCommitteeId,
            Integer cycle,
            Id recipientLegislatorId) {

        Map<String, String> params = new Map<String, String>{
            'cycle' => String.valueOf(cycle)
        };

        List<FECAPIService.ScheduleAContribution> apiResults =
            apiService.getScheduleAContributions(recipientCommitteeId, params);

        if (apiResults.isEmpty()) {
            return new List<PAC_Contribution__c>();
        }

        // Collect unique contributor committee IDs so we can upsert them first
        Set<String> contributorIds = new Set<String>();
        for (FECAPIService.ScheduleAContribution c : apiResults) {
            if (String.isNotBlank(c.contributorCommitteeId)) {
                contributorIds.add(c.contributorCommitteeId);
            }
        }

        // Ensure contributor FEC_Committee__c records exist
        ensureCommitteesExist(contributorIds, cycle);

        // Build lookup maps: committeeId → Salesforce record Id
        Map<String, Id> committeeIdMap = buildCommitteeIdMap(contributorIds, recipientCommitteeId);

        // Build lookup map: contributor committee FEC id → Account Id
        Map<String, Id> contributorFecIdToAccountMap =
            buildContributorAccountMap(contributorIds, committeeIdMap);

        // Build PAC_Contribution__c records
        List<PAC_Contribution__c> contributions = new List<PAC_Contribution__c>();
        Id recipientCommitteeSfId = committeeIdMap.get(recipientCommitteeId);

        for (FECAPIService.ScheduleAContribution apiC : apiResults) {
            if (String.isBlank(apiC.transactionId)) {
                continue;
            }
            PAC_Contribution__c rec = new PAC_Contribution__c();
            rec.Transaction_ID__c     = apiC.transactionId;
            rec.Contribution_Amount__c = apiC.contributionAmount;
            rec.Contribution_Date__c  = apiC.contributionDate;
            rec.Filing_Date__c        = apiC.filingDate;
            rec.Cycle__c              = apiC.cycle;
            rec.Last_Sync_Date__c     = Datetime.now();
            rec.Recipient_Committee__c = recipientCommitteeSfId;

            if (recipientLegislatorId != null) {
                rec.Recipient_Legislator__c = recipientLegislatorId;
            }

            if (String.isNotBlank(apiC.contributorCommitteeId)) {
                Id contribSfId = committeeIdMap.get(apiC.contributorCommitteeId);
                rec.Contributor_Committee__c = contribSfId;
                if (contributorFecIdToAccountMap.containsKey(apiC.contributorCommitteeId)) {
                    rec.Contributing_Account__c =
                        contributorFecIdToAccountMap.get(apiC.contributorCommitteeId);
                }
            }

            contributions.add(rec);
        }

        if (!contributions.isEmpty()) {
            upsert contributions Transaction_ID__c;
        }

        return contributions;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    /**
     * Ensures FEC_Committee__c records exist for all listed committee IDs.
     * Only syncs committees we don't already have; existing ones are skipped.
     */
    private void ensureCommitteesExist(Set<String> committeeIds, Integer cycle) {
        if (committeeIds.isEmpty()) {
            return;
        }
        // Find which IDs we already have
        Map<String, Boolean> existing = new Map<String, Boolean>();
        for (FEC_Committee__c c : [
            SELECT FEC_Committee_ID__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c IN :committeeIds
        ]) {
            existing.put(c.FEC_Committee_ID__c, true);
        }

        List<String> toSync = new List<String>();
        for (String cId : committeeIds) {
            if (!existing.containsKey(cId)) {
                toSync.add(cId);
            }
        }
        if (!toSync.isEmpty()) {
            committeeSync.syncCommittees(toSync, cycle);
        }
    }

    /**
     * Returns a map of FEC committee ID → Salesforce record Id for
     * the given set of committee IDs plus the recipient.
     */
    private Map<String, Id> buildCommitteeIdMap(
            Set<String> contributorIds,
            String recipientCommitteeId) {

        Set<String> allIds = new Set<String>(contributorIds);
        allIds.add(recipientCommitteeId);

        Map<String, Id> result = new Map<String, Id>();
        for (FEC_Committee__c c : [
            SELECT Id, FEC_Committee_ID__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c IN :allIds
        ]) {
            result.put(c.FEC_Committee_ID__c, c.Id);
        }
        return result;
    }

    /**
     * Returns a map of contributor committee FEC id -> Account Id.
     *
     * Mapping priority:
     * 1) Account.FEC_ID__c
     * 2) Account.Corporate_PAC_Committee__c (fallback)
     */
    private Map<String, Id> buildContributorAccountMap(
            Set<String> contributorFecIds,
            Map<String, Id> committeeIdMap) {

        Map<String, Id> result = new Map<String, Id>();
        if (contributorFecIds == null || contributorFecIds.isEmpty()) {
            return result;
        }

        Map<String, Schema.SObjectField> accountFields =
            Schema.SObjectType.Account.fields.getMap();

        // Primary mapping by Account.FEC_ID__c (text FEC identifier).
        if (accountFields.containsKey('FEC_ID__c')) {
            Set<String> ambiguousFecIds = new Set<String>();
            for (Account acc : [
                SELECT Id, FEC_ID__c
                FROM Account
                WHERE FEC_ID__c IN :contributorFecIds
            ]) {
                if (String.isBlank(acc.FEC_ID__c)) {
                    continue;
                }

                if (ambiguousFecIds.contains(acc.FEC_ID__c)) {
                    continue;
                }

                if (result.containsKey(acc.FEC_ID__c)
                        && result.get(acc.FEC_ID__c) != acc.Id) {
                    // Do not auto-link when multiple Accounts share same FEC id.
                    result.remove(acc.FEC_ID__c);
                    ambiguousFecIds.add(acc.FEC_ID__c);
                    System.debug(LoggingLevel.WARN,
                        'FECPACContributionSync: multiple Accounts found for FEC_ID__c='
                        + acc.FEC_ID__c + '. Skipping account auto-link for this FEC id.');
                    continue;
                }

                result.put(acc.FEC_ID__c, acc.Id);
            }
        }

        // Fallback mapping via Account.Corporate_PAC_Committee__c lookup.
        if (accountFields.containsKey('Corporate_PAC_Committee__c')) {
            Set<Id> contributorCommitteeSfIds = new Set<Id>();
            Map<Id, String> committeeSfIdToFecId = new Map<Id, String>();

            for (String contributorFecId : contributorFecIds) {
                Id committeeSfId = committeeIdMap.get(contributorFecId);
                if (committeeSfId != null) {
                    contributorCommitteeSfIds.add(committeeSfId);
                    committeeSfIdToFecId.put(committeeSfId, contributorFecId);
                }
            }

            if (!contributorCommitteeSfIds.isEmpty()) {
                for (Account acc : [
                    SELECT Id, Corporate_PAC_Committee__c
                    FROM Account
                    WHERE Corporate_PAC_Committee__c IN :contributorCommitteeSfIds
                ]) {
                    String contributorFecId =
                        committeeSfIdToFecId.get(acc.Corporate_PAC_Committee__c);
                    if (String.isBlank(contributorFecId)) {
                        continue;
                    }
                    if (!result.containsKey(contributorFecId)) {
                        result.put(contributorFecId, acc.Id);
                    }
                }
            }
        }

        return result;
    }
}
