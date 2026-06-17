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
 *   4. Only create PAC_Contribution__c rows when the contributor maps to an
 *      Account via Account.FEC_ID__c, and set Contributing_Account__c.
 */
public with sharing class FECPACContributionSync {

    public class SyncWindowResult {
        public Integer startPage;
        public Integer endPage;
        public Integer totalPages;
        public Integer recordsUpserted;
        public Boolean hasMorePages;
        public Integer nextPage;
    }

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
            'cycle' => String.valueOf(cycle),
            'entity_type' => 'PAC'
        };

        List<FECAPIService.ScheduleAContribution> apiResults =
            apiService.getScheduleAContributions(recipientCommitteeId, params);

        return syncContributionsFromApiResults(
            recipientCommitteeId,
            cycle,
            recipientLegislatorId,
            apiResults
        );
    }

    /**
     * Syncs a bounded page window so large committee cycles can be processed
     * across chained queueables without CPU timeout.
     */
    public SyncWindowResult syncContributionsWindow(
            String recipientCommitteeId,
            Integer cycle,
            Id recipientLegislatorId,
            Integer startPage,
            Integer maxPagesPerRun) {

        Map<String, String> params = new Map<String, String>{
            'cycle' => String.valueOf(cycle),
            'entity_type' => 'PAC'
        };

        FECAPIService.ScheduleAWindowResult window =
            apiService.getScheduleAContributionsWindow(
                recipientCommitteeId,
                params,
                startPage,
                maxPagesPerRun
            );

        List<PAC_Contribution__c> upserted = syncContributionsFromApiResults(
            recipientCommitteeId,
            cycle,
            recipientLegislatorId,
            window.contributions
        );

        SyncWindowResult out = new SyncWindowResult();
        out.startPage = window.startPage;
        out.endPage = window.endPage;
        out.totalPages = window.totalPages;
        out.recordsUpserted = upserted.size();
        out.hasMorePages = (window.endPage < window.totalPages);
        out.nextPage = out.hasMorePages ? (window.endPage + 1) : null;
        return out;
    }

    private List<PAC_Contribution__c> syncContributionsFromApiResults(
            String recipientCommitteeId,
            Integer cycle,
            Id recipientLegislatorId,
            List<FECAPIService.ScheduleAContribution> apiResults) {

        if (apiResults == null || apiResults.isEmpty()) {
            return new List<PAC_Contribution__c>();
        }

        // Collect unique contributor committee IDs so we can upsert them first
        Set<String> contributorIds = new Set<String>();
        for (FECAPIService.ScheduleAContribution c : apiResults) {
            String normalizedContributorId = normalizeFecId(c.contributorCommitteeId);
            if (normalizedContributorId != null) {
                contributorIds.add(normalizedContributorId);
            }
        }

        // Build lookup map: contributor committee FEC id → Account Id
        Map<String, Id> contributorFecIdToAccountMap =
            buildContributorAccountMap(contributorIds);

        // Only materialize contributor committees that are linked to Accounts.
        Set<String> linkedContributorIds = new Set<String>();
        linkedContributorIds.addAll(contributorFecIdToAccountMap.keySet());

        // Ensure only account-linked contributor FEC_Committee__c records exist.
        ensureCommitteesExist(linkedContributorIds, cycle);

        // Build lookup maps: committeeId → Salesforce record Id
        Map<String, Id> committeeIdMap = buildCommitteeIdMap(linkedContributorIds, recipientCommitteeId);
        Map<String, String> committeeNameMap = buildCommitteeNameMap(linkedContributorIds, recipientCommitteeId);

        // Build PAC_Contribution__c records
        List<PAC_Contribution__c> contributions = new List<PAC_Contribution__c>();
        Set<String> seenTransactionIds = new Set<String>();
        Integer duplicateTransactionCount = 0;
        Integer skippedUnlinkedContributorCount = 0;
        Id recipientCommitteeSfId = committeeIdMap.get(recipientCommitteeId);
        String recipientCommitteeName = committeeNameMap.get(recipientCommitteeId);
        Map<String, Schema.SObjectField> pacFields =
            Schema.SObjectType.PAC_Contribution__c.fields.getMap();

        for (FECAPIService.ScheduleAContribution apiC : apiResults) {
            if (String.isBlank(apiC.transactionId)) {
                continue;
            }
            if (seenTransactionIds.contains(apiC.transactionId)) {
                duplicateTransactionCount++;
                continue;
            }

            String normalizedContributorId = normalizeFecId(apiC.contributorCommitteeId);
            Id contributingAccountId = normalizedContributorId != null
                ? contributorFecIdToAccountMap.get(normalizedContributorId)
                : null;
            if (contributingAccountId == null) {
                skippedUnlinkedContributorCount++;
                continue;
            }

            seenTransactionIds.add(apiC.transactionId);

            PAC_Contribution__c rec = new PAC_Contribution__c();
            rec.Transaction_ID__c     = apiC.transactionId;
            rec.Source_Name__c        = apiC.contributorName;
            rec.Source_FEC_ID__c      = normalizedContributorId;
            rec.Contributor_Committee_Name__c = committeeNameMap.get(normalizedContributorId);
            rec.Recipient_Committee_Name__c = recipientCommitteeName;
            rec.Contribution_Amount__c = apiC.contributionAmount;
            rec.Contribution_Date__c  = apiC.contributionDate;
            rec.Filing_Date__c        = apiC.filingDate;
            rec.Cycle__c              = apiC.cycle;
            rec.Last_Sync_Date__c     = Datetime.now();
            rec.Recipient_Committee__c = recipientCommitteeSfId;

                if (recipientLegislatorId != null
                    && pacFields.containsKey('Recipient_Legislator__c')) {
                rec.Recipient_Legislator__c = recipientLegislatorId;
            }

            if (normalizedContributorId != null) {
                Id contribSfId = committeeIdMap.get(normalizedContributorId);
                rec.Contributor_Committee__c = contribSfId;
            }
            rec.Contributing_Account__c = contributingAccountId;

            contributions.add(rec);
        }

        if (!contributions.isEmpty()) {
            upsert contributions Transaction_ID__c;
        }

        if (duplicateTransactionCount > 0) {
            System.debug(LoggingLevel.WARN,
                'FECPACContributionSync: skipped duplicate transaction ids in batch. committee='
                + recipientCommitteeId
                + ' duplicatesSkipped=' + duplicateTransactionCount);
        }
        if (skippedUnlinkedContributorCount > 0) {
            System.debug(LoggingLevel.DEBUG,
            'FECPACContributionSync: skipped contributions without Account.FEC_ID__c match. committee='
                + recipientCommitteeId
            + ' skippedUnlinked=' + skippedUnlinkedContributorCount);
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
     * Returns a map of FEC committee ID → committee name for reporting.
     */
    private Map<String, String> buildCommitteeNameMap(
            Set<String> contributorIds,
            String recipientCommitteeId) {

        Set<String> allIds = new Set<String>(contributorIds);
        allIds.add(recipientCommitteeId);

        Map<String, String> result = new Map<String, String>();
        for (FEC_Committee__c c : [
            SELECT FEC_Committee_ID__c, Committee_Name__c, Name
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c IN :allIds
        ]) {
            String committeeName = String.isNotBlank(c.Committee_Name__c)
                ? c.Committee_Name__c
                : c.Name;
            result.put(c.FEC_Committee_ID__c, committeeName);
        }
        return result;
    }

    /**
     * Returns a map of contributor committee FEC id -> Account Id using
     * Account.FEC_ID__c only.
     */
    private Map<String, Id> buildContributorAccountMap(
            Set<String> contributorFecIds) {

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
                String normalizedFecId = normalizeFecId(acc.FEC_ID__c);
                if (normalizedFecId == null) {
                    continue;
                }

                if (ambiguousFecIds.contains(normalizedFecId)) {
                    continue;
                }

                if (result.containsKey(normalizedFecId)
                        && result.get(normalizedFecId) != acc.Id) {
                    // Do not auto-link when multiple Accounts share same FEC id.
                    result.remove(normalizedFecId);
                    ambiguousFecIds.add(normalizedFecId);
                    System.debug(LoggingLevel.WARN,
                        'FECPACContributionSync: multiple Accounts found for FEC_ID__c='
                        + normalizedFecId + '. Skipping account auto-link for this FEC id.');
                    continue;
                }

                result.put(normalizedFecId, acc.Id);
            }
        }

        return result;
    }

    private static String normalizeFecId(String fecId) {
        if (String.isBlank(fecId)) {
            return null;
        }
        return fecId.trim().toUpperCase();
    }
}
