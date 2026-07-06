/**
 * FECDataSyncScheduler
 *
 * Schedulable Apex class that kicks off FECDataSyncBatch on a cron schedule.
 *
 * Setup (run once from Developer Console after production launch):
 *   FECDataSyncScheduler.scheduleAll();
 *
 * Manual one-off trigger (Developer Console):
 *   FECDataSyncScheduler.runNow();
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
        runNow();
    }

    /**
     * Executes FECDataSyncBatch immediately.
     * Safe to call from the Developer Console for a manual one-off run.
     */
    public static void runNow() {
        Database.executeBatch(new FECDataSyncBatch(), 1);
    }

    /**
     * Schedules four annual sync jobs: January 15, April 15, July 15, and October 15 at 6 AM.
     * Idempotent — already-active jobs are skipped to prevent duplicates.
     * Run once from the Developer Console after production launch.
     */
    public static void scheduleAll() {
        Map<String, String> jobs = new Map<String, String>{
            'FEC Data Sync - Jan 15' => '0 0 6 15 1 ?',
            'FEC Data Sync - Apr 15' => '0 0 6 15 4 ?',
            'FEC Data Sync - Jul 15' => '0 0 6 15 7 ?',
            'FEC Data Sync - Oct 15' => '0 0 6 15 10 ?'
        };

        Set<String> existing = new Set<String>();
        for (CronTrigger ct : [
            SELECT CronJobDetail.Name FROM CronTrigger
            WHERE CronJobDetail.Name IN :jobs.keySet()
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ]) {
            existing.add(ct.CronJobDetail.Name);
        }

        for (String jobName : jobs.keySet()) {
            if (!existing.contains(jobName)) {
                System.schedule(jobName, jobs.get(jobName), new FECDataSyncScheduler());
                System.debug(LoggingLevel.INFO, 'FEC Data Sync: scheduled "' + jobName + '"');
            } else {
                System.debug(LoggingLevel.INFO, 'FEC Data Sync: "' + jobName + '" already active, skipped');
            }
        }
    }
}
