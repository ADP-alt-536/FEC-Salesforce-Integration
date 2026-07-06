/**
 * FECDataSyncScheduler
 *
 * Schedulable Apex class that kicks off FECDataSyncBatch on a cron schedule.
 *
 * Initial setup — run once from Developer Console:
 *   FECDataSyncScheduler.unscheduleAll();  // remove any existing FEC sync jobs
 *   FECDataSyncScheduler.scheduleAll();    // create the staggered schedule
 *
 * Manual one-off trigger (processes all legislators, no limit):
 *   FECDataSyncScheduler.runNow();
 */
public with sharing class FECDataSyncScheduler implements Schedulable {

    // Each staggered run handles this many legislators.
    // 100 legislators × ~2 committee API calls = ~200 calls per 2-hour window,
    // well under the FEC API personal key limit of 1,000 calls/hour.
    @TestVisible
    static final Integer PER_RUN_LIMIT = 100;

    // UTC hours for the six staggered runs on each sync day.
    // Six runs × 100 legislators = 600 slots, covering all 535 congressional legislators.
    @TestVisible
    static final List<Integer> RUN_HOURS = new List<Integer>{6, 8, 10, 12, 14, 16};

    private Integer cycle;
    private Integer queryOffset;
    private Integer queryLimit;

    public FECDataSyncScheduler() {
        this(null, 0, null);
    }

    public FECDataSyncScheduler(Integer cycle) {
        this(cycle, 0, null);
    }

    /**
     * @param cycle        Election cycle year (null = auto-detect at runtime)
     * @param queryOffset  Number of legislators to skip (ORDER BY Id)
     * @param queryLimit   Max legislators to process; null = all
     */
    public FECDataSyncScheduler(Integer cycle, Integer queryOffset, Integer queryLimit) {
        this.cycle       = cycle;
        this.queryOffset = queryOffset != null ? queryOffset : 0;
        this.queryLimit  = queryLimit;
    }

    public void execute(SchedulableContext ctx) {
        if (queryLimit != null && queryLimit > 0) {
            // SOQL OFFSET is not supported inside Batch Apex, so we pre-query the
            // slice of legislators here (schedulable context) and pass Ids to the batch.
            List<Legislator__c> slice = [
                SELECT Id FROM Legislator__c
                WHERE FEC_Candidate_ID__c != null
                ORDER BY Id
                LIMIT :queryLimit
                OFFSET :queryOffset
            ];
            if (slice.isEmpty()) {
                return;
            }
            List<Id> ids = new List<Id>();
            for (Legislator__c l : slice) {
                ids.add(l.Id);
            }
            Database.executeBatch(new FECDataSyncBatch(cycle, 1, ids), 1);
        } else {
            Database.executeBatch(new FECDataSyncBatch(cycle), 1);
        }
    }

    /**
     * Executes a full (no-limit) FECDataSyncBatch immediately.
     * Safe to call from the Developer Console for a manual one-off run.
     */
    public static void runNow() {
        Database.executeBatch(new FECDataSyncBatch(), 1);
    }

    /**
     * Aborts all active FEC Data Sync scheduled jobs.
     * Run this before scheduleAll() when replacing an existing schedule.
     */
    public static void unscheduleAll() {
        for (CronTrigger ct : [
            SELECT Id, CronJobDetail.Name FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'FEC Data Sync%'
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ]) {
            System.debug(LoggingLevel.INFO,
                'FEC Data Sync: aborting "' + ct.CronJobDetail.Name + '"');
            System.abortJob(ct.Id);
        }
    }

    /**
     * Schedules staggered batch runs on Jan 15, Apr 15, Jul 15, and Oct 15.
     * Each sync day gets six runs (RUN_HOURS), two hours apart. Each run processes
     * PER_RUN_LIMIT legislators via ORDER BY Id + OFFSET, so no legislator is
     * processed twice and API usage stays well under the hourly rate limit.
     *
     * Idempotent — already-active jobs with matching names are skipped.
     * Run unscheduleAll() first if replacing a previous schedule.
     */
    public static void scheduleAll() {
        // [label, day-of-month, month]
        List<String[]> syncDates = new List<String[]>{
            new String[]{'Jan 15', '15', '1'},
            new String[]{'Apr 15', '15', '4'},
            new String[]{'Jul 15', '15', '7'},
            new String[]{'Oct 15', '15', '10'}
        };

        Set<String> existing = new Set<String>();
        for (CronTrigger ct : [
            SELECT CronJobDetail.Name FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'FEC Data Sync%'
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ]) {
            existing.add(ct.CronJobDetail.Name);
        }

        for (String[] dateInfo : syncDates) {
            String label = dateInfo[0];
            String dom   = dateInfo[1];
            String month = dateInfo[2];

            for (Integer i = 0; i < RUN_HOURS.size(); i++) {
                Integer hour    = RUN_HOURS[i];
                Integer offset  = i * PER_RUN_LIMIT;
                String  hourStr = String.valueOf(hour).leftPad(2, '0');
                String  jobName = 'FEC Data Sync - ' + label + ' ' + hourStr + ':00';

                if (!existing.contains(jobName)) {
                    String cron = '0 0 ' + hour + ' ' + dom + ' ' + month + ' ?';
                    System.schedule(jobName, cron,
                        new FECDataSyncScheduler(null, offset, PER_RUN_LIMIT));
                    System.debug(LoggingLevel.INFO,
                        'FEC Data Sync: scheduled "' + jobName + '"');
                } else {
                    System.debug(LoggingLevel.INFO,
                        'FEC Data Sync: "' + jobName + '" already active, skipped');
                }
            }
        }
    }
}
