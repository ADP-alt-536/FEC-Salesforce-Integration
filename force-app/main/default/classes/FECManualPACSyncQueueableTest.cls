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
        System.assertEquals(10, FECManualPACSyncQueueable.reducePagesPerRun(null));
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
}
