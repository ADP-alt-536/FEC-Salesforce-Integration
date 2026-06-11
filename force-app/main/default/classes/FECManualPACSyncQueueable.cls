public with sharing class FECManualPACSyncQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer DEFAULT_START_PAGE = 1;
    private static final Integer DEFAULT_PAGES_PER_RUN = 20;

    private final String recipientCommitteeId;
    private final Integer cycleYear;
    private final Id legislatorId;
    private final Integer startPage;
    private final Integer pagesPerRun;

    public FECManualPACSyncQueueable(String recipientCommitteeId, Integer cycleYear, Id legislatorId) {
        this(recipientCommitteeId, cycleYear, legislatorId, DEFAULT_START_PAGE, DEFAULT_PAGES_PER_RUN);
    }

    public FECManualPACSyncQueueable(
            String recipientCommitteeId,
            Integer cycleYear,
            Id legislatorId,
            Integer startPage,
            Integer pagesPerRun) {
        this.recipientCommitteeId = recipientCommitteeId;
        this.cycleYear = cycleYear;
        this.legislatorId = legislatorId;
        this.startPage = (startPage == null || startPage < 1) ? DEFAULT_START_PAGE : startPage;
        this.pagesPerRun = (pagesPerRun == null || pagesPerRun < 1) ? DEFAULT_PAGES_PER_RUN : pagesPerRun;
    }

    public void execute(QueueableContext context) {
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
            Id nextJobId = System.enqueueJob(new FECManualPACSyncQueueable(
                recipientCommitteeId,
                cycleYear,
                legislatorId,
                synced.nextPage,
                pagesPerRun
            ));
            System.debug('FECManualPACSyncQueueable chained next job: ' + nextJobId
                + ' starting at page ' + synced.nextPage);
        }
    }
}
