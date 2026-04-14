/**
 * FECDataSyncScheduler
 *
 * Schedulable Apex class that kicks off FECDataSyncBatch on a cron schedule.
 *
 * To schedule nightly at 2 AM:
 *   System.schedule(
 *       'FEC Data Sync - Nightly',
 *       '0 0 2 * * ?',
 *       new FECDataSyncScheduler()
 *   );
 *
 * To schedule with a specific cycle year:
 *   System.schedule(
 *       'FEC Data Sync 2026',
 *       '0 0 2 * * ?',
 *       new FECDataSyncScheduler(2026)
 *   );
 */
public with sharing class FECDataSyncScheduler implements Schedulable {

    private Integer cycle;

    /** Uses the current / upcoming election cycle determined at runtime. */
    public FECDataSyncScheduler() {
        this.cycle = null; // resolved by FECDataSyncBatch constructor
    }

    /**
     * @param cycle  Election cycle year to sync (e.g. 2026)
     */
    public FECDataSyncScheduler(Integer cycle) {
        this.cycle = cycle;
    }

    public void execute(SchedulableContext ctx) {
        FECDataSyncBatch batch = (cycle != null)
            ? new FECDataSyncBatch(cycle)
            : new FECDataSyncBatch();
        Database.executeBatch(batch, 5);
    }
}
