package com.microsoft.azure.functions.mailbox.model;

import java.util.List;

/**
 * Input for the StoreInCosmos activity.
 * Combines email metadata with the fan-in attachment results
 * for final persistence in Cosmos DB.
 */
public class StoreDocumentInput {
    private String graphMessageId;
    private String internetMessageId;
    private String subject;
    private String fromAddress;
    private String fromName;
    private String receivedDateTime;
    private String bodyPreview;
    private List<AttachmentResult> attachments;

    public StoreDocumentInput() {}

    public String getGraphMessageId() { return graphMessageId; }
    public void setGraphMessageId(String graphMessageId) { this.graphMessageId = graphMessageId; }

    public String getInternetMessageId() { return internetMessageId; }
    public void setInternetMessageId(String internetMessageId) { this.internetMessageId = internetMessageId; }

    public String getSubject() { return subject; }
    public void setSubject(String subject) { this.subject = subject; }

    public String getFromAddress() { return fromAddress; }
    public void setFromAddress(String fromAddress) { this.fromAddress = fromAddress; }

    public String getFromName() { return fromName; }
    public void setFromName(String fromName) { this.fromName = fromName; }

    public String getReceivedDateTime() { return receivedDateTime; }
    public void setReceivedDateTime(String receivedDateTime) { this.receivedDateTime = receivedDateTime; }

    public String getBodyPreview() { return bodyPreview; }
    public void setBodyPreview(String bodyPreview) { this.bodyPreview = bodyPreview; }

    public List<AttachmentResult> getAttachments() { return attachments; }
    public void setAttachments(List<AttachmentResult> attachments) { this.attachments = attachments; }
}
