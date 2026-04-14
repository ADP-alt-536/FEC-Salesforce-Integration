/**
 * FECAPIServiceTest
 *
 * Unit tests for FECAPIService. HTTP callouts are intercepted by FECAPIMock.
 */
@IsTest
private class FECAPIServiceTest {

    // ─── getCommitteeFinancials ───────────────────────────────────────────────

    @IsTest
    static void testGetCommitteeFinancials_success() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        FECAPIService.CommitteeFinancials fin =
            svc.getCommitteeFinancials('C00177436', 2024);
        Test.stopTest();

        System.assertNotEquals(null, fin, 'CommitteeFinancials should not be null');
        System.assertEquals('Test Committee', fin.committeeName,  'Committee name mismatch');
        System.assertEquals('House',          fin.committeeType,  'Committee type mismatch');
        System.assertEquals('Authorized',     fin.designation,    'Designation mismatch');
        System.assertEquals(500000.00,        fin.cashOnHand,     'Cash on hand mismatch');
        System.assertEquals(1000000.00,       fin.totalReceipts,  'Total receipts mismatch');
        System.assertEquals(500000.00,        fin.totalDisbursements, 'Disbursements mismatch');
        System.assertEquals(2024,             fin.cycle,          'Cycle mismatch');
    }

    @IsTest
    static void testGetCommitteeFinancials_emptyResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS_EMPTY));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        FECAPIService.CommitteeFinancials fin =
            svc.getCommitteeFinancials('C00177436', 2024);
        Test.stopTest();

        System.assertEquals(null, fin, 'Empty results should return null');
    }

    @IsTest
    static void testGetCommitteeFinancials_nullCommitteeId() {
        Test.startTest();
        FECAPIService svc = new FECAPIService();
        FECAPIService.CommitteeFinancials fin =
            svc.getCommitteeFinancials(null, 2024);
        Test.stopTest();

        System.assertEquals(null, fin, 'Null committeeId should return null');
    }

    // ─── getScheduleAContributions ────────────────────────────────────────────

    @IsTest
    static void testGetScheduleAContributions_filtersPACOnly() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        List<FECAPIService.ScheduleAContribution> contribs =
            svc.getScheduleAContributions('C00177436',
                new Map<String, String>{'cycle' => '2024'});
        Test.stopTest();

        // The mock returns 2 records: 1 COMMITTEE (PAC) and 1 INDIVIDUAL
        // Only the COMMITTEE one should be returned
        System.assertEquals(1, contribs.size(), 'Only PAC (COMMITTEE) contributions should be returned');
        System.assertEquals('TRN001',     contribs[0].transactionId,          'Transaction ID mismatch');
        System.assertEquals('C00111111',  contribs[0].contributorCommitteeId, 'Contributor committee mismatch');
        System.assertEquals(5000.00,      contribs[0].contributionAmount,     'Amount mismatch');
        System.assertEquals('COMMITTEE',  contribs[0].entityType,             'Entity type mismatch');
    }

    @IsTest
    static void testGetScheduleAContributions_emptyResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        List<FECAPIService.ScheduleAContribution> contribs =
            svc.getScheduleAContributions('C00177436', null);
        Test.stopTest();

        System.assertEquals(0, contribs.size(), 'Empty results should return empty list');
    }

    @IsTest
    static void testGetScheduleAContributions_nullCommitteeId() {
        Test.startTest();
        FECAPIService svc = new FECAPIService();
        List<FECAPIService.ScheduleAContribution> contribs =
            svc.getScheduleAContributions(null, null);
        Test.stopTest();

        System.assertEquals(0, contribs.size(), 'Null committeeId should return empty list');
    }

    // ─── getPrincipalCommitteeId ──────────────────────────────────────────────

    @IsTest
    static void testGetPrincipalCommitteeId_found() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        String committeeId = svc.getPrincipalCommitteeId('H00001234', 2024);
        Test.stopTest();

        System.assertEquals('C00177436', committeeId, 'Principal committee ID mismatch');
    }

    @IsTest
    static void testGetPrincipalCommitteeId_notFound() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        String committeeId = svc.getPrincipalCommitteeId('H00001234', 2024);
        Test.stopTest();

        System.assertEquals(null, committeeId, 'Empty result should return null');
    }

    @IsTest
    static void testGetPrincipalCommitteeId_nullCandidateId() {
        Test.startTest();
        FECAPIService svc = new FECAPIService();
        String committeeId = svc.getPrincipalCommitteeId(null, 2024);
        Test.stopTest();

        System.assertEquals(null, committeeId, 'Null candidateId should return null');
    }

    // ─── Error handling ───────────────────────────────────────────────────────

    @IsTest
    static void testApiError_throwsFECAPIException() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.ERROR_500));

        Test.startTest();
        FECAPIService svc = new FECAPIService();
        Boolean exceptionThrown = false;
        try {
            svc.getCommitteeFinancials('C00177436', 2024);
        } catch (FECAPIService.FECAPIException ex) {
            exceptionThrown = true;
            System.assert(ex.getMessage().contains('500'), 'Exception message should contain status code');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'FECAPIException should have been thrown on HTTP 500');
    }

    // ─── mapCommitteeType (private, tested via @TestVisible) ─────────────────

    @IsTest
    static void testMapCommitteeType_variations() {
        System.assertEquals('House',         FECAPIService.mapCommitteeType('House of Representatives'));
        System.assertEquals('Senate',        FECAPIService.mapCommitteeType('Senate'));
        System.assertEquals('Presidential',  FECAPIService.mapCommitteeType('Presidential'));
        System.assertEquals('PAC',           FECAPIService.mapCommitteeType('PAC - Non-Qualified'));
        System.assertEquals('Super PAC',     FECAPIService.mapCommitteeType('Super PAC'));
        System.assertEquals('Party',         FECAPIService.mapCommitteeType('Party - Qualified'));
        System.assertEquals(null,            FECAPIService.mapCommitteeType('Unknown'));
        System.assertEquals(null,            FECAPIService.mapCommitteeType(null));
    }
}
