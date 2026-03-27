package com.core.az;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredential;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;
import reactor.core.publisher.Mono;

import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class AzContentUnderstandingTest {

    private static final String ENDPOINT = "https://test.cognitiveservices.azure.com";
    private static final String TEST_TOKEN = "test-bearer-token";
    private static final String ANALYZER_ID = "test-analyzer";
    private static final String OPERATION_ID = "op-123";

    @Mock
    private AzConnection mockConnection;

    @Mock
    private DefaultAzureCredential mockCredential;

    @Mock
    private HttpClient mockHttpClient;

    private AzContentUnderstanding cu;

    @BeforeEach
    void setUp() {
        when(mockConnection.getContentUnderstandingEndpoint()).thenReturn(ENDPOINT);
        when(mockConnection.getContentUnderstandingCredential()).thenReturn(mockCredential);
        when(mockConnection.getContentUnderstandingHttpClient()).thenReturn(mockHttpClient);

        cu = new AzContentUnderstanding(mockConnection);
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    private void stubBearerToken() {
        AccessToken token = new AccessToken(TEST_TOKEN, OffsetDateTime.now().plusHours(1));
        when(mockCredential.getToken(any(TokenRequestContext.class)))
                .thenReturn(Mono.just(token));
    }

    @SuppressWarnings("unchecked")
    private HttpResponse<String> mockResponse(int statusCode, String body) {
        return mockResponse(statusCode, body, Collections.emptyMap());
    }

    @SuppressWarnings("unchecked")
    private HttpResponse<String> mockResponse(int statusCode, String body,
                                               Map<String, List<String>> headers) {
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(statusCode);
        when(response.body()).thenReturn(body);
        when(response.headers()).thenReturn(
                HttpHeaders.of(headers, (k, v) -> true));
        return response;
    }

    // ---------------------------------------------------------------
    //  Static API URL constants
    // ---------------------------------------------------------------

    @Test
    void apiVersion_matchesAzEnvNamesConstant() {
        assertEquals(AzEnvNames.STATIC_CONTENT_UNDERSTANDING_API_VERSION,
                AzContentUnderstanding.API_VERSION);
    }

    @Test
    void apiListAnalyzers_containsExpectedPath() {
        assertTrue(AzContentUnderstanding.API_LIST_ANALYZERS
                .contains("/contentunderstanding/analyzers"));
        assertTrue(AzContentUnderstanding.API_LIST_ANALYZERS
                .contains("api-version="));
    }

    @Test
    void apiCreateAnalyzer_containsFormatPlaceholder() {
        assertTrue(AzContentUnderstanding.API_CREATE_ANALYZER.contains("%s"));
        assertTrue(AzContentUnderstanding.API_CREATE_ANALYZER
                .contains("/contentunderstanding/analyzers/"));
    }

    @Test
    void apiDeleteAnalyzer_containsFormatPlaceholder() {
        assertTrue(AzContentUnderstanding.API_DELETE_ANALYZER.contains("%s"));
    }

    @Test
    void apiAnalyze_containsAnalyzeSuffix() {
        assertTrue(AzContentUnderstanding.API_ANALYZE.contains(":analyze"));
    }

    @Test
    void apiGetAnalyzeResult_containsResultsPath() {
        assertTrue(AzContentUnderstanding.API_GET_ANALYZE_RESULT
                .contains("/analyzerResults/"));
    }

    @Test
    void apiGetOperationStatus_containsOperationsPath() {
        assertTrue(AzContentUnderstanding.API_GET_OPERATION_STATUS
                .contains("/operations/"));
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    @Test
    void constructor_readsEndpointAndCredentialFromConnection() {
        verify(mockConnection).getContentUnderstandingEndpoint();
        verify(mockConnection).getContentUnderstandingCredential();
    }

    // ---------------------------------------------------------------
    //  getOperationIdFromJson (static)
    // ---------------------------------------------------------------

    @Test
    void getOperationIdFromJson_returnsOperationId() {
        String json = "{\"operationId\":\"op-123\",\"status\":\"running\"}";
        assertEquals("op-123", AzContentUnderstanding.getOperationIdFromJson(json));
    }

    @Test
    void getOperationIdFromJson_throwsWhenFieldMissing() {
        String json = "{\"status\":\"running\"}";
        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> AzContentUnderstanding.getOperationIdFromJson(json));
        assertTrue(ex.getMessage().contains("operationId"));
    }

    @Test
    void getOperationIdFromJson_throwsOnInvalidJson() {
        assertThrows(RuntimeException.class,
                () -> AzContentUnderstanding.getOperationIdFromJson("not-json"));
    }

    // ---------------------------------------------------------------
    //  getContentAnalyzerStatusFromJson (static)
    // ---------------------------------------------------------------

    @Test
    void getContentAnalyzerStatusFromJson_returnsStatus() {
        String json = "{\"status\":\"succeeded\"}";
        assertEquals("succeeded",
                AzContentUnderstanding.getContentAnalyzerStatusFromJson(json));
    }

    @Test
    void getContentAnalyzerStatusFromJson_throwsWhenFieldMissing() {
        String json = "{\"operationId\":\"op-1\"}";
        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> AzContentUnderstanding.getContentAnalyzerStatusFromJson(json));
        assertTrue(ex.getMessage().contains("status"));
    }

    @Test
    void getContentAnalyzerStatusFromJson_throwsOnInvalidJson() {
        assertThrows(RuntimeException.class,
                () -> AzContentUnderstanding.getContentAnalyzerStatusFromJson("{{bad"));
    }

    // ---------------------------------------------------------------
    //  getContentAnalyzerIdsFromJson (static)
    // ---------------------------------------------------------------

    @Test
    void getContentAnalyzerIdsFromJson_returnsFirstAnalyzerMetadata() {
        String json = """
                {
                  "value": [
                    {
                      "analyzerId": "my-analyzer",
                      "displayName": "My Analyzer",
                      "description": "desc",
                      "baseAnalyzerId": "prebuilt-document"
                    }
                  ]
                }
                """;
        Map<String, String> result =
                AzContentUnderstanding.getContentAnalyzerIdsFromJson(json);

        assertEquals("my-analyzer", result.get("id"));
        assertEquals("My Analyzer", result.get("name"));
        assertEquals("desc", result.get("description"));
        assertEquals("prebuilt-document", result.get("baseAnalyzerId"));
    }

    @Test
    void getContentAnalyzerIdsFromJson_returnsEmptyMapWhenNoAnalyzers() {
        String json = "{\"value\":[]}";
        assertTrue(AzContentUnderstanding
                .getContentAnalyzerIdsFromJson(json).isEmpty());
    }

    @Test
    void getContentAnalyzerIdsFromJson_returnsEmptyMapWhenValueMissing() {
        String json = "{\"other\":\"data\"}";
        assertTrue(AzContentUnderstanding
                .getContentAnalyzerIdsFromJson(json).isEmpty());
    }

    @Test
    void getContentAnalyzerIdsFromJson_throwsOnInvalidJson() {
        assertThrows(RuntimeException.class,
                () -> AzContentUnderstanding
                        .getContentAnalyzerIdsFromJson("not-json"));
    }

    // ---------------------------------------------------------------
    //  createContentAnalyzer
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void createContentAnalyzer_success201_returnsEnrichedBody() throws Exception {
        stubBearerToken();
        String responseBody = "{\"analyzerId\":\"test-analyzer\"}";
        String opLocation = ENDPOINT + "/operations/" + OPERATION_ID
                + "?api-version=" + AzContentUnderstanding.API_VERSION;

        HttpResponse<String> response = mockResponse(201, responseBody,
                Map.of("Operation-Location", List.of(opLocation)));

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.createContentAnalyzer(ANALYZER_ID,
                "{\"scenario\":\"test\"}");

        assertTrue(result.contains("operationId"));
        assertTrue(result.contains(OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void createContentAnalyzer_success200_returnsBody() throws Exception {
        stubBearerToken();
        String responseBody = "{\"analyzerId\":\"test-analyzer\"}";

        HttpResponse<String> response = mockResponse(200, responseBody);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.createContentAnalyzer(ANALYZER_ID, "{}");
        assertTrue(result.contains("test-analyzer"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void createContentAnalyzer_failure400_throwsRuntimeException() throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(400,
                "{\"error\":\"bad request\"}");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.createContentAnalyzer(ANALYZER_ID, "{}"));
        assertTrue(ex.getMessage().contains("400"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void createContentAnalyzer_ioException_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("connection refused"));

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.createContentAnalyzer(ANALYZER_ID, "{}"));
        assertInstanceOf(IOException.class, ex.getCause());
    }

    // ---------------------------------------------------------------
    //  deleteContentAnalyzer
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void deleteContentAnalyzer_success204_returnsSyntheticJson()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(204, "");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.deleteContentAnalyzer(ANALYZER_ID);
        assertTrue(result.contains("\"status\":\"deleted\""));
        assertTrue(result.contains("204"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void deleteContentAnalyzer_success204_nullBody_returnsSyntheticJson()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(204, null);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.deleteContentAnalyzer(ANALYZER_ID);
        assertTrue(result.contains("\"status\":\"deleted\""));
    }

    @Test
    @SuppressWarnings("unchecked")
    void deleteContentAnalyzer_success200_returnsBody() throws Exception {
        stubBearerToken();
        String body = "{\"status\":\"deleted\"}";
        HttpResponse<String> response = mockResponse(200, body);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertEquals(body, cu.deleteContentAnalyzer(ANALYZER_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void deleteContentAnalyzer_failure404_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(404,
                "{\"error\":\"not found\"}");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.deleteContentAnalyzer(ANALYZER_ID));
        assertTrue(ex.getMessage().contains("404"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void deleteContentAnalyzer_ioException_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("timeout"));

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.deleteContentAnalyzer(ANALYZER_ID));
        assertInstanceOf(IOException.class, ex.getCause());
    }

    // ---------------------------------------------------------------
    //  listContentAnalyzers
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void listContentAnalyzers_success_returnsBody() throws Exception {
        stubBearerToken();
        String body = "{\"value\":[]}";
        HttpResponse<String> response = mockResponse(200, body);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertEquals(body, cu.listContentAnalyzers());
    }

    @Test
    @SuppressWarnings("unchecked")
    void listContentAnalyzers_failure500_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(500, "server error");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertThrows(RuntimeException.class, () -> cu.listContentAnalyzers());
    }

    @Test
    @SuppressWarnings("unchecked")
    void listContentAnalyzers_ioException_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("network error"));

        assertThrows(RuntimeException.class, () -> cu.listContentAnalyzers());
    }

    // ---------------------------------------------------------------
    //  getOperationStatus
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void getOperationStatus_success_returnsBody() throws Exception {
        stubBearerToken();
        String body = "{\"status\":\"succeeded\"}";
        HttpResponse<String> response = mockResponse(200, body);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertEquals(body,
                cu.getOperationStatus(ANALYZER_ID, OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void getOperationStatus_failure404_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(404, "not found");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertThrows(RuntimeException.class,
                () -> cu.getOperationStatus(ANALYZER_ID, OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void getOperationStatus_ioException_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("timeout"));

        assertThrows(RuntimeException.class,
                () -> cu.getOperationStatus(ANALYZER_ID, OPERATION_ID));
    }

    // ---------------------------------------------------------------
    //  analyze
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void analyze_success202_returnsEnrichedBody() throws Exception {
        stubBearerToken();
        String responseBody = "{\"status\":\"running\"}";
        String opLocation = ENDPOINT + "/operations/" + OPERATION_ID
                + "?api-version=" + AzContentUnderstanding.API_VERSION;

        HttpResponse<String> response = mockResponse(202, responseBody,
                Map.of("Operation-Location", List.of(opLocation)));

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.analyze(ANALYZER_ID,
                "{\"url\":\"https://example.com/doc.pdf\"}");

        assertTrue(result.contains("operationId"));
        assertTrue(result.contains(OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void analyze_success202_emptyBody_returnsSyntheticJson() throws Exception {
        stubBearerToken();
        String opLocation = ENDPOINT + "/operations/" + OPERATION_ID
                + "?api-version=" + AzContentUnderstanding.API_VERSION;

        HttpResponse<String> response = mockResponse(202, "",
                Map.of("Operation-Location", List.of(opLocation)));

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.analyze(ANALYZER_ID, "{}");
        assertTrue(result.contains(OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void analyze_success200_noOperationHeader_returnsBodyAsIs()
            throws Exception {
        stubBearerToken();
        String responseBody = "{\"status\":\"completed\"}";
        HttpResponse<String> response = mockResponse(200, responseBody);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertEquals(responseBody, cu.analyze(ANALYZER_ID, "{}"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void analyze_failure400_throwsRuntimeException() throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(400, "bad request");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.analyze(ANALYZER_ID, "{}"));
        assertTrue(ex.getMessage().contains("400"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void analyze_ioException_throwsRuntimeException() throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("connection reset"));

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.analyze(ANALYZER_ID, "{}"));
        assertInstanceOf(IOException.class, ex.getCause());
    }

    // ---------------------------------------------------------------
    //  getAnalyzeResultsByOperationId
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void getAnalyzeResultsByOperationId_success_returnsBody()
            throws Exception {
        stubBearerToken();
        String body = "{\"status\":\"succeeded\",\"result\":{}}";
        HttpResponse<String> response = mockResponse(200, body);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertEquals(body,
                cu.getAnalyzeResultsByOperationId(ANALYZER_ID, OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void getAnalyzeResultsByOperationId_failure404_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        HttpResponse<String> response = mockResponse(404, "not found");

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        assertThrows(RuntimeException.class,
                () -> cu.getAnalyzeResultsByOperationId(
                        ANALYZER_ID, OPERATION_ID));
    }

    @Test
    @SuppressWarnings("unchecked")
    void getAnalyzeResultsByOperationId_ioException_throwsRuntimeException()
            throws Exception {
        stubBearerToken();
        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenThrow(new IOException("read timeout"));

        RuntimeException ex = assertThrows(RuntimeException.class,
                () -> cu.getAnalyzeResultsByOperationId(
                        ANALYZER_ID, OPERATION_ID));
        assertInstanceOf(IOException.class, ex.getCause());
    }

    // ---------------------------------------------------------------
    //  Operation-Location header parsing (via createContentAnalyzer)
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void operationLocationHeader_withResultsPath_extractsOperationId()
            throws Exception {
        stubBearerToken();
        String responseBody = "{\"analyzerId\":\"a1\"}";
        String opLocation = ENDPOINT + "/results/result-456?api-version="
                + AzContentUnderstanding.API_VERSION;

        HttpResponse<String> response = mockResponse(201, responseBody,
                Map.of("Operation-Location", List.of(opLocation)));

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.createContentAnalyzer(ANALYZER_ID, "{}");
        assertTrue(result.contains("result-456"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void operationLocationHeader_missing_bodyReturnedAsIs() throws Exception {
        stubBearerToken();
        String responseBody = "{\"analyzerId\":\"a1\"}";

        HttpResponse<String> response = mockResponse(201, responseBody);

        when(mockHttpClient.send(any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)))
                .thenReturn(response);

        String result = cu.createContentAnalyzer(ANALYZER_ID, "{}");
        // No operationId should be injected when header is absent
        assertFalse(result.contains("operationId"));
    }
}
