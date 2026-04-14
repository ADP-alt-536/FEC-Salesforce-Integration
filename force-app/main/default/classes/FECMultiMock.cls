/**
 * FECMultiMock
 *
 * An HttpCalloutMock that serves responses from a sequential list of mocks.
 * Each call to respond() returns the next mock's response in the list.
 * Used in tests that exercise code paths making multiple HTTP callouts.
 */
@IsTest
public class FECMultiMock implements HttpCalloutMock {

    private List<HttpCalloutMock> mocks;
    private Integer callIndex = 0;

    public FECMultiMock(List<HttpCalloutMock> mocks) {
        this.mocks = mocks;
    }

    public HttpResponse respond(HttpRequest req) {
        HttpCalloutMock mock = (callIndex < mocks.size())
            ? mocks[callIndex++]
            : mocks[mocks.size() - 1]; // replay last mock if list is exhausted
        return mock.respond(req);
    }
}
