/**
 * FECAPIMock
 *
 * HttpCalloutMock implementation for FEC API unit tests.
 * Supports different response scenarios via the MockType enum.
 */
@IsTest
public class FECAPIMock implements HttpCalloutMock {

    public enum MockType {
        COMMITTEE_FINANCIALS,
        COMMITTEE_FINANCIALS_ENDING_CASH,
        COMMITTEE_FINANCIALS_EMPTY,
        SCHEDULE_A_CONTRIBUTIONS,
        SCHEDULE_A_EMPTY,
        COMMITTEE_DETAILS,
        PRINCIPAL_COMMITTEE,
        PRINCIPAL_COMMITTEE_EMPTY,
        ERROR_500
    }

    private MockType mockType;

    public FECAPIMock(MockType mockType) {
        this.mockType = mockType;
    }

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        switch on mockType {
            when COMMITTEE_FINANCIALS {
                res.setStatusCode(200);
                res.setBody(committeeFinancialsJson());
            }
            when COMMITTEE_FINANCIALS_ENDING_CASH {
                res.setStatusCode(200);
                res.setBody(committeeFinancialsEndingCashJson());
            }
            when COMMITTEE_FINANCIALS_EMPTY {
                res.setStatusCode(200);
                res.setBody('{"results":[],"pagination":{"count":0}}');
            }
            when SCHEDULE_A_CONTRIBUTIONS {
                res.setStatusCode(200);
                res.setBody(scheduleAJson());
            }
            when SCHEDULE_A_EMPTY {
                res.setStatusCode(200);
                res.setBody('{"results":[],"pagination":{"count":0}}');
            }
            when COMMITTEE_DETAILS {
                res.setStatusCode(200);
                res.setBody(committeeDetailsJson());
            }
            when PRINCIPAL_COMMITTEE {
                res.setStatusCode(200);
                res.setBody(principalCommitteeJson());
            }
            when PRINCIPAL_COMMITTEE_EMPTY {
                res.setStatusCode(200);
                res.setBody('{"results":[],"pagination":{"count":0}}');
            }
            when ERROR_500 {
                res.setStatusCode(500);
                res.setBody('{"error":"Internal Server Error"}');
            }
        }
        return res;
    }

    // ─── Response Body Fixtures ───────────────────────────────────────────────

    private static String committeeFinancialsJson() {
        return '{"results":[{'
            + '"committee_name":"Test Committee",'
            + '"committee_type_full":"House",'
            + '"designation_full":"Authorized",'
            + '"cash_on_hand_end_period":500000.00,'
            + '"receipts":1000000.00,'
            + '"disbursements":500000.00,'
            + '"cycle":2024'
            + '}],"pagination":{"count":1}}';
    }

    private static String committeeFinancialsEndingCashJson() {
        return '{"results":[{'
            + '"committee_name":"Test Committee",'
            + '"committee_type_full":"House",'
            + '"designation_full":"Authorized",'
            + '"ending_cash_on_hand":750000.00,'
            + '"receipts":1200000.00,'
            + '"disbursements":450000.00,'
            + '"cycle":2024'
            + '}],"pagination":{"count":1}}';
    }

    private static String scheduleAJson() {
        return '{"results":['
            + '{"sub_id":"TRN001",'
            + '"contributor_committee_id":"C00111111",'
            + '"contributor_name":"ACME PAC",'
            + '"contribution_receipt_amount":5000.00,'
            + '"contribution_receipt_date":"2024-03-15",'
            + '"load_date":"2024-03-20",'
            + '"cycle":2024,'
            + '"entity_type":"COMMITTEE"},'
            + '{"sub_id":"TRN002",'
            + '"contributor_committee_id":null,'
            + '"contributor_name":"John Individual",'
            + '"contribution_receipt_amount":250.00,'
            + '"contribution_receipt_date":"2024-04-01",'
            + '"load_date":"2024-04-05",'
            + '"cycle":2024,'
            + '"entity_type":"INDIVIDUAL"}'
            + '],"pagination":{"count":2}}';
    }

    private static String committeeDetailsJson() {
        return '{"results":[{'
            + '"committee_id":"C00177436",'
            + '"name":"Sample Campaign Committee",'
            + '"committee_type":"H",'
            + '"committee_type_full":"House",'
            + '"designation":"P",'
            + '"designation_full":"Principal campaign committee"'
            + '}],"pagination":{"count":1}}';
    }

    private static String principalCommitteeJson() {
        return '{"results":[{'
            + '"committee_id":"C00177436",'
            + '"name":"Test Campaign Committee",'
            + '"designation":"P"'
            + '}],"pagination":{"count":1}}';
    }
}
