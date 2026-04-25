package com.microsoft.azure.functions.mailbox.model;

/**
 * Result of processing a single attachment, produced by the
 * ProcessAttachment activity and collected by the orchestrator for fan-in.
 */
public class AttachmentResult {
    private String attachmentName;
    private String blobUrl;
    private String contentType;
    private String analyzerName;
    private String analyzeOperationId;
    private String analyzeRequestDateTime;
    private String status;
    private String errorMessage;

    public AttachmentResult() {}

    public String getAttachmentName() { return attachmentName; }
    public void setAttachmentName(String attachmentName) { this.attachmentName = attachmentName; }

    public String getBlobUrl() { return blobUrl; }
    public void setBlobUrl(String blobUrl) { this.blobUrl = blobUrl; }

    public String getContentType() { return contentType; }
    public void setContentType(String contentType) { this.contentType = contentType; }

    public String getAnalyzerName() { return analyzerName; }
    public void setAnalyzerName(String analyzerName) { this.analyzerName = analyzerName; }

    public String getAnalyzeOperationId() { return analyzeOperationId; }
    public void setAnalyzeOperationId(String analyzeOperationId) { this.analyzeOperationId = analyzeOperationId; }

    public String getAnalyzeRequestDateTime() { return analyzeRequestDateTime; }
    public void setAnalyzeRequestDateTime(String analyzeRequestDateTime) { this.analyzeRequestDateTime = analyzeRequestDateTime; }

    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }

    public String getErrorMessage() { return errorMessage; }
    public void setErrorMessage(String errorMessage) { this.errorMessage = errorMessage; }
}
