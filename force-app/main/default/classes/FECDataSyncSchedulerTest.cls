@IsTest
private class FECDataSyncSchedulerTest {

    @IsTest
    static void testScheduleAllCreatesFourJobsAndIsIdempotent() {
        Test.startTest();
        FECDataSyncScheduler.scheduleAll();
        FECDataSyncScheduler.scheduleAll();
        Test.stopTest();

        List<CronTrigger> scheduled = [
            SELECT CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name IN (
                'FEC Data Sync - Jan 15',
                'FEC Data Sync - Apr 15',
                'FEC Data Sync - Jul 15',
                'FEC Data Sync - Oct 15'
            )
        ];

        System.assertEquals(4, scheduled.size(),
            'scheduleAll should create only one active job per configured quarter');
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
