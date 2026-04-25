package com.microsoft.azure.functions.mailbox.model;

import java.util.List;

/**
 * Serializable representation of an email and its attachment metadata,
 * produced by the FetchEmail activity and consumed by the orchestrator.
 */
public class EmailData {
    private String graphMessageId;
    private String internetMessageId;
    private String subject;
    private String fromAddress;
    private String fromName;
    private String receivedDateTime;
    private String bodyContent;
    private String bodyPreview;
    private String blobFolder;
    private String analyzersJson;
    private List<AttachmentInfo> attachments;

    public EmailData() {}

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

    public String getBodyContent() { return bodyContent; }
    public void setBodyContent(String bodyContent) { this.bodyContent = bodyContent; }

    public String getBodyPreview() { return bodyPreview; }
    public void setBodyPreview(String bodyPreview) { this.bodyPreview = bodyPreview; }

    public String getBlobFolder() { return blobFolder; }
    public void setBlobFolder(String blobFolder) { this.blobFolder = blobFolder; }

    public String getAnalyzersJson() { return analyzersJson; }
    public void setAnalyzersJson(String analyzersJson) { this.analyzersJson = analyzersJson; }

    public List<AttachmentInfo> getAttachments() { return attachments; }
    public void setAttachments(List<AttachmentInfo> attachments) { this.attachments = attachments; }
}
