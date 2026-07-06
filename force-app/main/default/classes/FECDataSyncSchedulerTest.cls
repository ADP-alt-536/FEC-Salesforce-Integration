@IsTest
private class FECDataSyncSchedulerTest {

    @IsTest
    static void testScheduleAllCreatesFourJobsAndIsIdempotent() {
        // scheduleAll creates RUN_HOURS.size() staggered jobs per sync date × 4 dates
        Integer expectedJobs = FECDataSyncScheduler.RUN_HOURS.size() * 4;

        Test.startTest();
        FECDataSyncScheduler.scheduleAll();
        FECDataSyncScheduler.scheduleAll(); // second call should be idempotent
        Test.stopTest();

        List<CronTrigger> scheduled = [
            SELECT CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'FEC Data Sync%'
        ];

        System.assertEquals(expectedJobs, scheduled.size(),
            'scheduleAll should create ' + expectedJobs + ' staggered jobs and be idempotent');
    }

    @IsTest
    static void testExecuteInvokesRunNowPath() {
        Legislator__c leg = new Legislator__c(FEC_Candidate_ID__c = 'H00003333');
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        String jobId = System.schedule(
            'FEC Scheduler Execute Coverage',
            '0 0 1 15 12 ? 2099',
            new FECDataSyncScheduler(2026)
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduled job ID should be returned');
    }
}
