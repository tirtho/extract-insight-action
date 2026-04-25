package com.core.az;

import com.azure.storage.queue.QueueClient;
import com.azure.storage.queue.models.QueueMessageItem;
import com.azure.storage.queue.models.SendMessageResult;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.List;

/**
 * Provides send, receive, peek, and delete operations for an Azure Storage Queue.
 *
 * <p>Uses {@link AzConnection} to obtain the authenticated {@link QueueClient}
 * (endpoint and queue name are sourced from Key Vault via
 * {@code StorageEndpoint} and {@code StorageQueueName}).</p>
 */
public class AzStorageQueue {

    private static final Logger LOG = LoggerFactory.getLogger(AzStorageQueue.class);

    private final QueueClient queueClient;

    /**
     * Creates a new AzStorageQueue backed by the queue configured in Key Vault.
     *
     * @param connection an {@link AzConnection} that supplies the queue client
     */
    public AzStorageQueue(AzConnection connection) {
        this.queueClient = connection.getStorageQueueClient();
        LOG.info("AzStorageQueue initialised – queue: {}", queueClient.getQueueName());
    }

    // ---------------------------------------------------------------
    //  Send operations
    // ---------------------------------------------------------------

    /**
     * Sends a message to the queue.
     *
     * @param messageText the message content (plain text or JSON string)
     * @return the {@link SendMessageResult} containing the message id and pop receipt
     */
    public SendMessageResult sendMessage(String messageText) {
        LOG.info("Sending message to queue '{}' ({} chars)", queueClient.getQueueName(), messageText.length());
        SendMessageResult result = queueClient.sendMessage(messageText);
        LOG.info("Message sent – messageId: {}", result.getMessageId());
        return result;
    }

    /**
     * Sends a message with a visibility timeout and time-to-live.
     *
     * @param messageText       the message content
     * @param visibilityTimeout how long the message is invisible after being enqueued
     * @param timeToLive        how long the message lives in the queue before expiring
     * @return the {@link SendMessageResult}
     */
    public SendMessageResult sendMessage(String messageText, Duration visibilityTimeout, Duration timeToLive) {
        LOG.info("Sending message to queue '{}' (visibilityTimeout={}, ttl={})",
                queueClient.getQueueName(), visibilityTimeout, timeToLive);
        SendMessageResult result = queueClient.sendMessageWithResponse(
                messageText, visibilityTimeout, timeToLive, null, null).getValue();
        LOG.info("Message sent – messageId: {}", result.getMessageId());
        return result;
    }

    // ---------------------------------------------------------------
    //  Receive operations
    // ---------------------------------------------------------------

    /**
     * Receives up to {@code maxMessages} messages from the queue.
     * Messages become invisible for the default 30-second visibility timeout.
     *
     * @param maxMessages the maximum number of messages to receive (1–32)
     * @return a list of {@link QueueMessageItem}s (may be empty)
     */
    public List<QueueMessageItem> receiveMessages(int maxMessages) {
        LOG.info("Receiving up to {} messages from queue '{}'", maxMessages, queueClient.getQueueName());
        List<QueueMessageItem> messages = queueClient.receiveMessages(maxMessages).stream().toList();
        LOG.info("Received {} messages", messages.size());
        return messages;
    }

    /**
     * Receives up to {@code maxMessages} messages with a custom visibility timeout.
     *
     * @param maxMessages       the maximum number of messages to receive (1–32)
     * @param visibilityTimeout how long received messages stay invisible
     * @return a list of {@link QueueMessageItem}s (may be empty)
     */
    public List<QueueMessageItem> receiveMessages(int maxMessages, Duration visibilityTimeout) {
        LOG.info("Receiving up to {} messages (visibilityTimeout={}) from queue '{}'",
                maxMessages, visibilityTimeout, queueClient.getQueueName());
        List<QueueMessageItem> messages = queueClient.receiveMessages(
                maxMessages, visibilityTimeout, null, null).stream().toList();
        LOG.info("Received {} messages", messages.size());
        return messages;
    }

    // ---------------------------------------------------------------
    //  Peek operations
    // ---------------------------------------------------------------

    /**
     * Peeks at up to {@code maxMessages} messages without making them invisible.
     *
     * @param maxMessages the maximum number of messages to peek (1–32)
     * @return a list of peeked {@link com.azure.storage.queue.models.PeekedMessageItem}s
     */
    public List<com.azure.storage.queue.models.PeekedMessageItem> peekMessages(int maxMessages) {
        LOG.info("Peeking at up to {} messages from queue '{}'", maxMessages, queueClient.getQueueName());
        var messages = queueClient.peekMessages(maxMessages, null, null).stream().toList();
        LOG.info("Peeked {} messages", messages.size());
        return messages;
    }

    // ---------------------------------------------------------------
    //  Delete operations
    // ---------------------------------------------------------------

    /**
     * Deletes a message from the queue after it has been received and processed.
     *
     * @param messageId  the message id (from {@link QueueMessageItem#getMessageId()})
     * @param popReceipt the pop receipt (from {@link QueueMessageItem#getPopReceipt()})
     */
    public void deleteMessage(String messageId, String popReceipt) {
        LOG.info("Deleting message '{}' from queue '{}'", messageId, queueClient.getQueueName());
        queueClient.deleteMessage(messageId, popReceipt);
        LOG.info("Message '{}' deleted", messageId);
    }

    // ---------------------------------------------------------------
    //  Utility operations
    // ---------------------------------------------------------------

    /**
     * Returns the approximate number of messages in the queue.
     *
     * @return the approximate message count
     */
    public int getApproximateMessageCount() {
        int count = queueClient.getProperties().getApproximateMessagesCount();
        LOG.info("Queue '{}' approximate message count: {}", queueClient.getQueueName(), count);
        return count;
    }

    /**
     * Clears all messages from the queue.
     */
    public void clearMessages() {
        LOG.info("Clearing all messages from queue '{}'", queueClient.getQueueName());
        queueClient.clearMessages();
        LOG.info("Queue '{}' cleared", queueClient.getQueueName());
    }
}
