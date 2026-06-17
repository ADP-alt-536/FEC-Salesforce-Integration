public with sharing class FECManualPACSyncQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer DEFAULT_START_PAGE = 1;
    private static final Integer DEFAULT_PAGES_PER_RUN = 5;
    @TestVisible private static final Integer LOCK_MINUTES = 60;
    @TestVisible private static final Integer MAX_TIMEOUT_RETRIES = 2;
    @TestVisible private static final Integer MIN_PAGES_PER_RUN = 1;

    private final String recipientCommitteeId;
    private final Integer cycleYear;
    private final Id legislatorId;
    private final Integer startPage;
    private final Integer pagesPerRun;
    private final String chainToken;
    private final Integer timeoutRetryCount;

    public FECManualPACSyncQueueable(String recipientCommitteeId, Integer cycleYear, Id legislatorId) {
        this(
            recipientCommitteeId,
            cycleYear,
            legislatorId,
            DEFAULT_START_PAGE,
            DEFAULT_PAGES_PER_RUN,
            createChainToken(),
            0
        );
    }

    public FECManualPACSyncQueueable(
            String recipientCommitteeId,
            Integer cycleYear,
            Id legislatorId,
            Integer startPage,
            Integer pagesPerRun) {
        this(
            recipientCommitteeId,
            cycleYear,
            legislatorId,
            startPage,
            pagesPerRun,
            createChainToken(),
            0
        );
    }

    private FECManualPACSyncQueueable(
            String recipientCommitteeId,
            Integer cycleYear,
            Id legislatorId,
            Integer startPage,
            Integer pagesPerRun,
            String chainToken,
            Integer timeoutRetryCount) {
        this.recipientCommitteeId = recipientCommitteeId;
        this.cycleYear = cycleYear;
        this.legislatorId = legislatorId;
        this.startPage = (startPage == null || startPage < 1) ? DEFAULT_START_PAGE : startPage;
        this.pagesPerRun = (pagesPerRun == null || pagesPerRun < 1) ? DEFAULT_PAGES_PER_RUN : pagesPerRun;
        this.chainToken = chainToken;
        this.timeoutRetryCount = (timeoutRetryCount == null || timeoutRetryCount < 0)
            ? 0
            : timeoutRetryCount;
    }

    /**
     * Enqueues the first job in a guarded chain.
     * Returns null when a chain is already active for the committee+cycle.
     */
    public static Id enqueueIfNotActive(String recipientCommitteeId, Integer cycleYear, Id legislatorId) {
        String token = createChainToken();
        if (!acquireChainLock(recipientCommitteeId, cycleYear, token, Datetime.now())) {
            System.debug(LoggingLevel.WARN,
                'FECManualPACSyncQueueable enqueue skipped: active chain exists. committee='
                + recipientCommitteeId + ' | cycle=' + cycleYear);
            return null;
        }

        return System.enqueueJob(new FECManualPACSyncQueueable(
            recipientCommitteeId,
            cycleYear,
            legislatorId,
            DEFAULT_START_PAGE,
            DEFAULT_PAGES_PER_RUN,
            token,
            0
        ));
    }

    public void execute(QueueableContext context) {
        Datetime nowValue = Datetime.now();
        if (!hasValidChainLock(recipientCommitteeId, cycleYear, chainToken, nowValue)) {
            System.debug(LoggingLevel.WARN,
                'FECManualPACSyncQueueable execute skipped: active chain lock held by another token. committee='
                + recipientCommitteeId + ' | cycle=' + cycleYear);
            return;
        }

        try {
            FECPACContributionSync.SyncWindowResult synced =
                new FECPACContributionSync().syncContributionsWindow(
                recipientCommitteeId,
                cycleYear,
                legislatorId,
                startPage,
                pagesPerRun
            );

            System.debug('FECManualPACSyncQueueable page window complete. committee=' + recipientCommitteeId
                + ' | cycle=' + cycleYear
                + ' | pages=' + synced.startPage + '-' + synced.endPage + '/' + synced.totalPages
                + ' | recordsUpserted=' + synced.recordsUpserted);

            if (synced.hasMorePages == true) {
                if (!acquireChainLock(recipientCommitteeId, cycleYear, chainToken, Datetime.now())) {
                    System.debug(LoggingLevel.WARN,
                        'FECManualPACSyncQueueable chain stopped: unable to refresh chain lock. committee='
                        + recipientCommitteeId + ' | cycle=' + cycleYear);
                    return;
                }

                Id nextJobId = System.enqueueJob(new FECManualPACSyncQueueable(
                    recipientCommitteeId,
                    cycleYear,
                    legislatorId,
                    synced.nextPage,
                    pagesPerRun,
                    chainToken,
                    0
                ));
                System.debug('FECManualPACSyncQueueable chained next job: ' + nextJobId
                    + ' starting at page ' + synced.nextPage);
            } else {
                releaseChainLock(recipientCommitteeId, cycleYear, chainToken);
            }
        } catch (Exception ex) {
            if (isCalloutTimeout(ex) && timeoutRetryCount < MAX_TIMEOUT_RETRIES) {
                Integer reducedPagesPerRun = reducePagesPerRun(pagesPerRun);
                if (acquireChainLock(recipientCommitteeId, cycleYear, chainToken, Datetime.now())) {
                    Id retryJobId = System.enqueueJob(new FECManualPACSyncQueueable(
                        recipientCommitteeId,
                        cycleYear,
                        legislatorId,
                        startPage,
                        reducedPagesPerRun,
                        chainToken,
                        timeoutRetryCount + 1
                    ));
                    System.debug(LoggingLevel.WARN,
                        'FECManualPACSyncQueueable timeout retry enqueued. committee=' + recipientCommitteeId
                        + ' | cycle=' + cycleYear
                        + ' | page=' + startPage
                        + ' | pagesPerRun=' + reducedPagesPerRun
                        + ' | retry=' + (timeoutRetryCount + 1)
                        + ' | jobId=' + retryJobId);
                    return;
                }
            }

            releaseChainLock(recipientCommitteeId, cycleYear, chainToken);
            throw ex;
        }
    }

    private static String createChainToken() {
        return String.valueOf(Crypto.getRandomLong())
            + '-' + String.valueOf(Datetime.now().getTime());
    }

    @TestVisible
    private static Boolean isCalloutTimeout(Exception ex) {
        if (!(ex instanceof CalloutException) || ex.getMessage() == null) {
            return false;
        }
        String msg = ex.getMessage().toLowerCase();
        return msg.contains('maximum time allotted for callout')
            || msg.contains('read timed out');
    }

    @TestVisible
    private static Integer reducePagesPerRun(Integer value) {
        Integer current = (value == null || value < MIN_PAGES_PER_RUN)
            ? DEFAULT_PAGES_PER_RUN
            : value;
        Integer reduced = Integer.valueOf(Math.floor(Decimal.valueOf(current) / 2));
        return Math.max(MIN_PAGES_PER_RUN, reduced);
    }

    @TestVisible
    private static Boolean hasValidChainLock(
            String committeeId,
            Integer cycle,
            String token,
            Datetime nowValue) {

        if (String.isBlank(committeeId) || cycle == null || String.isBlank(token)) {
            return false;
        }

        List<FEC_Committee__c> committees = [
            SELECT PAC_Sync_In_Progress__c,
                   PAC_Sync_Cycle__c,
                   PAC_Sync_Lock_Expires__c,
                   PAC_Sync_Chain_Token__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = :committeeId
            LIMIT 1
        ];
        if (committees.isEmpty()) {
            return false;
        }

        FEC_Committee__c committee = committees[0];
        return committee.PAC_Sync_In_Progress__c == true
            && committee.PAC_Sync_Cycle__c == cycle
            && committee.PAC_Sync_Chain_Token__c == token
            && committee.PAC_Sync_Lock_Expires__c != null
            && committee.PAC_Sync_Lock_Expires__c > nowValue;
    }

    @TestVisible
    private static Boolean acquireChainLock(
            String committeeId,
            Integer cycle,
            String token,
            Datetime nowValue) {

        if (String.isBlank(committeeId) || cycle == null || String.isBlank(token)) {
            return false;
        }

        List<FEC_Committee__c> committees = [
            SELECT Id,
                   PAC_Sync_In_Progress__c,
                   PAC_Sync_Cycle__c,
                   PAC_Sync_Lock_Expires__c,
                   PAC_Sync_Chain_Token__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = :committeeId
            LIMIT 1
            FOR UPDATE
        ];
        if (committees.isEmpty()) {
            return false;
        }

        FEC_Committee__c committee = committees[0];
        Boolean lockIsActive =
            committee.PAC_Sync_In_Progress__c == true
            && committee.PAC_Sync_Cycle__c == cycle
            && committee.PAC_Sync_Lock_Expires__c != null
            && committee.PAC_Sync_Lock_Expires__c > nowValue
            && committee.PAC_Sync_Chain_Token__c != token;

        if (lockIsActive) {
            return false;
        }

        committee.PAC_Sync_In_Progress__c = true;
        committee.PAC_Sync_Cycle__c = cycle;
        committee.PAC_Sync_Chain_Token__c = token;
        committee.PAC_Sync_Lock_Expires__c = nowValue.addMinutes(LOCK_MINUTES);
        update committee;
        return true;
    }

    @TestVisible
    private static void releaseChainLock(String committeeId, Integer cycle, String token) {
        if (String.isBlank(committeeId) || cycle == null || String.isBlank(token)) {
            return;
        }

        List<FEC_Committee__c> committees = [
            SELECT Id,
                   PAC_Sync_In_Progress__c,
                   PAC_Sync_Cycle__c,
                   PAC_Sync_Chain_Token__c,
                   PAC_Sync_Lock_Expires__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = :committeeId
            LIMIT 1
            FOR UPDATE
        ];
        if (committees.isEmpty()) {
            return;
        }

        FEC_Committee__c committee = committees[0];
        if (committee.PAC_Sync_Chain_Token__c != token
                || committee.PAC_Sync_Cycle__c != cycle) {
            return;
        }

        committee.PAC_Sync_In_Progress__c = false;
        committee.PAC_Sync_Cycle__c = null;
        committee.PAC_Sync_Chain_Token__c = null;
        committee.PAC_Sync_Lock_Expires__c = null;
        update committee;
    }
}
