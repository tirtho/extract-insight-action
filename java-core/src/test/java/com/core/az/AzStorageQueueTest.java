package com.core.az;

import com.azure.core.http.rest.Response;
import com.azure.storage.queue.QueueClient;
import com.azure.storage.queue.models.PeekedMessageItem;
import com.azure.storage.queue.models.QueueMessageItem;
import com.azure.storage.queue.models.QueueProperties;
import com.azure.storage.queue.models.SendMessageResult;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import com.azure.core.http.rest.PagedIterable;

import java.time.Duration;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class AzStorageQueueTest {

    private static final String QUEUE_NAME = "test-queue";
    private static final String MESSAGE_TEXT = "{\"key\":\"value\"}";
    private static final String MESSAGE_ID = "msg-123";
    private static final String POP_RECEIPT = "pop-abc";

    @Mock
    private AzConnection mockConnection;

    @Mock
    private QueueClient mockQueueClient;

    private AzStorageQueue storageQueue;

    @BeforeEach
    void setUp() {
        when(mockQueueClient.getQueueName()).thenReturn(QUEUE_NAME);
        when(mockConnection.getStorageQueueClient()).thenReturn(mockQueueClient);

        storageQueue = new AzStorageQueue(mockConnection);
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    @Test
    void constructor_getsQueueClientFromConnection() {
        verify(mockConnection).getStorageQueueClient();
    }

    // ---------------------------------------------------------------
    //  sendMessage (simple)
    // ---------------------------------------------------------------

    @Test
    void sendMessage_delegatesToQueueClient() {
        SendMessageResult mockResult = mock(SendMessageResult.class);
        when(mockResult.getMessageId()).thenReturn(MESSAGE_ID);
        when(mockQueueClient.sendMessage(MESSAGE_TEXT)).thenReturn(mockResult);

        SendMessageResult result = storageQueue.sendMessage(MESSAGE_TEXT);

        assertEquals(MESSAGE_ID, result.getMessageId());
        verify(mockQueueClient).sendMessage(MESSAGE_TEXT);
    }

    // ---------------------------------------------------------------
    //  sendMessage (with visibility timeout and TTL)
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void sendMessage_withTimeouts_delegatesToQueueClient() {
        Duration visibility = Duration.ofSeconds(30);
        Duration ttl = Duration.ofHours(1);

        SendMessageResult mockResult = mock(SendMessageResult.class);
        when(mockResult.getMessageId()).thenReturn(MESSAGE_ID);

        Response<SendMessageResult> mockResponse = mock(Response.class);
        when(mockResponse.getValue()).thenReturn(mockResult);
        when(mockQueueClient.sendMessageWithResponse(eq(MESSAGE_TEXT), eq(visibility), eq(ttl), isNull(), isNull()))
                .thenReturn(mockResponse);

        SendMessageResult result = storageQueue.sendMessage(MESSAGE_TEXT, visibility, ttl);

        assertEquals(MESSAGE_ID, result.getMessageId());
        verify(mockQueueClient).sendMessageWithResponse(MESSAGE_TEXT, visibility, ttl, null, null);
    }

    // ---------------------------------------------------------------
    //  receiveMessages (simple)
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void receiveMessages_returnsMessageList() {
        QueueMessageItem item1 = mock(QueueMessageItem.class);
        QueueMessageItem item2 = mock(QueueMessageItem.class);

        PagedIterable<QueueMessageItem> pagedIterable = mock(PagedIterable.class);
        when(pagedIterable.stream()).thenReturn(Stream.of(item1, item2));
        when(mockQueueClient.receiveMessages(5)).thenReturn(pagedIterable);

        List<QueueMessageItem> result = storageQueue.receiveMessages(5);

        assertEquals(2, result.size());
        verify(mockQueueClient).receiveMessages(5);
    }

    @Test
    @SuppressWarnings("unchecked")
    void receiveMessages_emptyQueue_returnsEmptyList() {
        PagedIterable<QueueMessageItem> pagedIterable = mock(PagedIterable.class);
        when(pagedIterable.stream()).thenReturn(Stream.empty());
        when(mockQueueClient.receiveMessages(10)).thenReturn(pagedIterable);

        List<QueueMessageItem> result = storageQueue.receiveMessages(10);

        assertTrue(result.isEmpty());
    }

    // ---------------------------------------------------------------
    //  receiveMessages (with visibility timeout)
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void receiveMessages_withVisibilityTimeout_delegatesToQueueClient() {
        Duration visibility = Duration.ofMinutes(5);
        QueueMessageItem item = mock(QueueMessageItem.class);

        PagedIterable<QueueMessageItem> pagedIterable = mock(PagedIterable.class);
        when(pagedIterable.stream()).thenReturn(Stream.of(item));
        when(mockQueueClient.receiveMessages(3, visibility, null, null)).thenReturn(pagedIterable);

        List<QueueMessageItem> result = storageQueue.receiveMessages(3, visibility);

        assertEquals(1, result.size());
        verify(mockQueueClient).receiveMessages(3, visibility, null, null);
    }

    // ---------------------------------------------------------------
    //  peekMessages
    // ---------------------------------------------------------------

    @Test
    @SuppressWarnings("unchecked")
    void peekMessages_returnsPeekedItems() {
        PeekedMessageItem item1 = mock(PeekedMessageItem.class);
        PeekedMessageItem item2 = mock(PeekedMessageItem.class);

        PagedIterable<PeekedMessageItem> pagedIterable = mock(PagedIterable.class);
        when(pagedIterable.stream()).thenReturn(Stream.of(item1, item2));
        when(mockQueueClient.peekMessages(5, null, null)).thenReturn(pagedIterable);

        var result = storageQueue.peekMessages(5);

        assertEquals(2, result.size());
        verify(mockQueueClient).peekMessages(5, null, null);
    }

    // ---------------------------------------------------------------
    //  deleteMessage
    // ---------------------------------------------------------------

    @Test
    void deleteMessage_delegatesToQueueClient() {
        storageQueue.deleteMessage(MESSAGE_ID, POP_RECEIPT);

        verify(mockQueueClient).deleteMessage(MESSAGE_ID, POP_RECEIPT);
    }

    // ---------------------------------------------------------------
    //  getApproximateMessageCount
    // ---------------------------------------------------------------

    @Test
    void getApproximateMessageCount_returnsCount() {
        QueueProperties mockProperties = mock(QueueProperties.class);
        when(mockProperties.getApproximateMessagesCount()).thenReturn(42);
        when(mockQueueClient.getProperties()).thenReturn(mockProperties);

        int count = storageQueue.getApproximateMessageCount();

        assertEquals(42, count);
        verify(mockQueueClient).getProperties();
    }

    // ---------------------------------------------------------------
    //  clearMessages
    // ---------------------------------------------------------------

    @Test
    void clearMessages_delegatesToQueueClient() {
        storageQueue.clearMessages();

        verify(mockQueueClient).clearMessages();
    }
}
