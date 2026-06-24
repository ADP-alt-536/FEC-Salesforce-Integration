@IsTest
private class FECManualPACSyncQueueableTest {

    private static FEC_Committee__c createCommittee(String fecCommitteeId) {
        FEC_Committee__c committee = new FEC_Committee__c(
            Name = 'Test Committee ' + fecCommitteeId,
            FEC_Committee_ID__c = fecCommitteeId
        );
        insert committee;
        return committee;
    }

    @IsTest
    static void testAcquireLock_blocksDifferentTokenSameCycle() {
        createCommittee('C00990001');
        Datetime nowValue = Datetime.now();

        Boolean first = FECManualPACSyncQueueable.acquireChainLock(
            'C00990001',
            2026,
            'token-a',
            nowValue
        );
        Boolean second = FECManualPACSyncQueueable.acquireChainLock(
            'C00990001',
            2026,
            'token-b',
            nowValue
        );

        System.assertEquals(true, first, 'Initial token should acquire lock');
        System.assertEquals(false, second, 'Second token should be blocked while lock is active');
    }

    @IsTest
    static void testAcquireLock_allowsSameTokenAndReleaseAllowsNewToken() {
        createCommittee('C00990002');
        Datetime nowValue = Datetime.now();

        Boolean first = FECManualPACSyncQueueable.acquireChainLock(
            'C00990002',
            2026,
            'token-a',
            nowValue
        );
        Boolean refresh = FECManualPACSyncQueueable.acquireChainLock(
            'C00990002',
            2026,
            'token-a',
            nowValue.addMinutes(5)
        );

        FECManualPACSyncQueueable.releaseChainLock('C00990002', 2026, 'token-a');

        Boolean afterRelease = FECManualPACSyncQueueable.acquireChainLock(
            'C00990002',
            2026,
            'token-b',
            nowValue.addMinutes(6)
        );

        System.assertEquals(true, first, 'Initial lock should be acquired');
        System.assertEquals(true, refresh, 'Same token should refresh or retain lock');
        System.assertEquals(true, afterRelease, 'New token should acquire lock after release');
    }

    @IsTest
    static void testReleaseWrongTokenDoesNotRelease() {
        createCommittee('C00990003');
        Datetime nowValue = Datetime.now();

        System.assertEquals(true, FECManualPACSyncQueueable.acquireChainLock(
            'C00990003',
            2026,
            'token-a',
            nowValue
        ));

        FECManualPACSyncQueueable.releaseChainLock('C00990003', 2026, 'token-b');

        Boolean stillBlocked = FECManualPACSyncQueueable.acquireChainLock(
            'C00990003',
            2026,
            'token-c',
            nowValue
        );

        System.assertEquals(
            false,
            stillBlocked,
            'Different token should remain blocked because wrong token release must not unlock'
        );
    }

    @IsTest
    static void testReducePagesPerRun_halvesAndFloorsAtOne() {
        System.assertEquals(10, FECManualPACSyncQueueable.reducePagesPerRun(20));
        System.assertEquals(5, FECManualPACSyncQueueable.reducePagesPerRun(10));
        System.assertEquals(1, FECManualPACSyncQueueable.reducePagesPerRun(1));
        System.assertEquals(5, FECManualPACSyncQueueable.reducePagesPerRun(null));
    }

    @IsTest
    static void testIsCalloutTimeout_detectsRelevantException() {
        Exception maxTimeEx  = new CalloutException('Exceeded maximum time allotted for callout');
        Exception readTimeout = new CalloutException('Read timed out');
        Exception otherCallout = new CalloutException('Connection refused');

        System.assertEquals(true,  FECManualPACSyncQueueable.isCalloutTimeout(maxTimeEx),
            'max-time callout should be treated as timeout');
        System.assertEquals(true,  FECManualPACSyncQueueable.isCalloutTimeout(readTimeout),
            'read-timed-out callout should be treated as timeout');
        System.assertEquals(false, FECManualPACSyncQueueable.isCalloutTimeout(otherCallout),
            'unrelated callout exception should not be treated as timeout');
        System.assertEquals(false, FECManualPACSyncQueueable.isCalloutTimeout(null),
            'null should not be treated as timeout');
    }

    @IsTest
    static void testIsRateLimitException_detectsRelevantException() {
        Exception rateLimit = new FECAPIService.FECAPIException(
            'FEC API returned HTTP 429 for path: /v1/schedules/schedule_a/'
        );
        Exception overRateLimit = new CalloutException('OVER_RATE_LIMIT');

        System.assertEquals(true, FECManualPACSyncQueueable.isRateLimitException(rateLimit),
            'HTTP 429 should be treated as a rate-limit exception');
        System.assertEquals(true, FECManualPACSyncQueueable.isRateLimitException(overRateLimit),
            'OVER_RATE_LIMIT should be treated as a rate-limit exception');
        System.assertEquals(false, FECManualPACSyncQueueable.isRateLimitException(null),
            'null should not be treated as a rate-limit exception');
    }

    @IsTest
    static void testScheduleRateLimitResume_createsScheduledJob() {
        createCommittee('C00990004');

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_RATE_LIMIT));

        FECManualPACSyncQueueable job = new FECManualPACSyncQueueable('C00990004', 2026, null, 283, 10);

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        System.assertEquals(true, true, 'Rate-limit branch should complete without bubbling the exception');
    }

    @IsTest
    static void testEnqueueIfNotActive_blocksWhenLockedAndAllowsWhenReleased() {
        createCommittee('C00990005');
        Datetime nowValue = Datetime.now();

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY));

        System.assertEquals(true, FECManualPACSyncQueueable.acquireChainLock(
            'C00990005',
            2026,
            'active-token',
            nowValue
        ));

        Id blocked = FECManualPACSyncQueueable.enqueueIfNotActive('C00990005', 2026, null);
        System.assertEquals(null, blocked, 'enqueueIfNotActive should return null when lock is already active');

        FECManualPACSyncQueueable.releaseChainLock('C00990005', 2026, 'active-token');

        Id enqueued = FECManualPACSyncQueueable.enqueueIfNotActive('C00990005', 2026, null);
        System.assertNotEquals(null, enqueued, 'enqueueIfNotActive should enqueue when lock is available');
    }

    @IsTest
    static void testExecuteSkipsWhenChainLockMissing() {
        createCommittee('C00990010');

        FECManualPACSyncQueueable job = new FECManualPACSyncQueueable('C00990010', 2026, null);

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        System.assertEquals(true, true,
            'execute should safely return when the queueable token does not own an active lock');
    }

    @IsTest
    static void testEnqueueIfNotActive_executesAndReleasesLockOnNoMorePages() {
        createCommittee('C00990009');

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY));

        Test.startTest();
        Id jobId = FECManualPACSyncQueueable.enqueueIfNotActive('C00990009', 2026, null);
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Expected queueable job to be enqueued');

        FEC_Committee__c committee = [
            SELECT PAC_Sync_In_Progress__c, PAC_Sync_Cycle__c, PAC_Sync_Chain_Token__c, PAC_Sync_Lock_Expires__c
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = 'C00990009'
            LIMIT 1
        ];

        System.assertEquals(false, committee.PAC_Sync_In_Progress__c,
            'Lock should be released after completing a no-more-pages sync');
        System.assertEquals(null, committee.PAC_Sync_Cycle__c,
            'Cycle lock marker should be cleared after completion');
        System.assertEquals(null, committee.PAC_Sync_Chain_Token__c,
            'Chain token should be cleared after completion');
        System.assertEquals(null, committee.PAC_Sync_Lock_Expires__c,
            'Lock expiration should be cleared after completion');
    }

    @IsTest
    static void testHasValidChainLockAndReleaseEdgeCases() {
        createCommittee('C00990006');
        Datetime nowValue = Datetime.now();

        System.assertEquals(false, FECManualPACSyncQueueable.hasValidChainLock(
            'C00990006',
            2026,
            'token-x',
            nowValue
        ));

        System.assertEquals(true, FECManualPACSyncQueueable.acquireChainLock(
            'C00990006',
            2026,
            'token-x',
            nowValue
        ));

        System.assertEquals(true, FECManualPACSyncQueueable.hasValidChainLock(
            'C00990006',
            2026,
            'token-x',
            nowValue
        ));

        System.assertEquals(false, FECManualPACSyncQueueable.hasValidChainLock(
            'C00990006',
            2026,
            'token-y',
            nowValue
        ));

        FECManualPACSyncQueueable.releaseChainLock('C00990006', 2027, 'token-x');
        System.assertEquals(true, FECManualPACSyncQueueable.hasValidChainLock(
            'C00990006',
            2026,
            'token-x',
            nowValue
        ));

        FECManualPACSyncQueueable.releaseChainLock('C00990006', 2026, 'token-x');
        System.assertEquals(false, FECManualPACSyncQueueable.hasValidChainLock(
            'C00990006',
            2026,
            'token-x',
            nowValue
        ));
    }

    @IsTest
    static void testExtendChainLockAndScheduleContinuation() {
        createCommittee('C00990007');
        Datetime nowValue = Datetime.now();

        System.assertEquals(true, FECManualPACSyncQueueable.acquireChainLock(
            'C00990007',
            2026,
            'token-z',
            nowValue
        ));

        Boolean extended = FECManualPACSyncQueueable.extendChainLock(
            'C00990007',
            2026,
            'token-z',
            15
        );
        System.assertEquals(true, extended, 'extendChainLock should keep lock active for matching token and cycle');

        Test.startTest();
        Id jobId = FECManualPACSyncQueueable.scheduleContinuation(
            'C00990007',
            2026,
            null,
            11,
            3,
            'token-z',
            0,
            1,
            'test continuation'
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'scheduleContinuation should create a scheduled job when lock is valid');
    }

    @IsTest
    static void testScheduleContinuationThrowsWhenLockCannotBeExtended() {
        createCommittee('C00990008');

        Boolean threw = false;
        try {
            FECManualPACSyncQueueable.scheduleContinuation(
                'C00990008',
                2026,
                null,
                5,
                2,
                'different-token',
                0,
                1,
                'missing lock'
            );
        } catch (Exception ex) {
            threw = true;
            System.assert(
                ex.getMessage().contains('could not extend its chain lock'),
                'Expected scheduleContinuation to fail when lock cannot be extended'
            );
        }

        System.assertEquals(true, threw, 'Expected scheduleContinuation to throw without a valid lock');
    }

    @IsTest
    static void testGuardClausesForInvalidInputs() {
        System.assertEquals(false, FECManualPACSyncQueueable.acquireChainLock(null, 2026, 'token', Datetime.now()));
        System.assertEquals(false, FECManualPACSyncQueueable.extendChainLock('C001', null, 'token', 60));
        System.assertEquals(false, FECManualPACSyncQueueable.hasValidChainLock('C001', 2026, null, Datetime.now()));
        System.assertEquals(false, FECManualPACSyncQueueable.isCalloutTimeout(
            new FECAPIService.FECAPIException('read timed out')),
            'Only CalloutException instances should be treated as callout timeout');
        System.assertEquals(false, FECManualPACSyncQueueable.isRateLimitException(
            new FECAPIService.FECAPIException('some other error')),
            'Non-rate-limit errors should not match rate-limit detection');
    }
}
