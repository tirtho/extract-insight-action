package com.microsoft.azure.functions.mailbox.model;

/**
 * Input for the ProcessAttachment activity.
 * Contains everything the activity needs to fetch, store, and analyze
 * a single email attachment without orchestrator state passing through.
 */
public class ProcessAttachmentInput {
    private String graphMessageId;
    private String attachmentId;
    private String attachmentName;
    private String contentType;
    private String odataType;
    private String blobFolder;
    private String analyzersJson;

    public ProcessAttachmentInput() {}

    public String getGraphMessageId() { return graphMessageId; }
    public void setGraphMessageId(String graphMessageId) { this.graphMessageId = graphMessageId; }

    public String getAttachmentId() { return attachmentId; }
    public void setAttachmentId(String attachmentId) { this.attachmentId = attachmentId; }

    public String getAttachmentName() { return attachmentName; }
    public void setAttachmentName(String attachmentName) { this.attachmentName = attachmentName; }

    public String getContentType() { return contentType; }
    public void setContentType(String contentType) { this.contentType = contentType; }

    public String getOdataType() { return odataType; }
    public void setOdataType(String odataType) { this.odataType = odataType; }

    public String getBlobFolder() { return blobFolder; }
    public void setBlobFolder(String blobFolder) { this.blobFolder = blobFolder; }

    public String getAnalyzersJson() { return analyzersJson; }
    public void setAnalyzersJson(String analyzersJson) { this.analyzersJson = analyzersJson; }
}
