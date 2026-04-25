package com.microsoft.azure.functions.mailbox.model;

/**
 * Lightweight attachment descriptor returned by the FetchEmail activity.
 * Contains only the metadata needed by the orchestrator to fan out
 * ProcessAttachment activities. Does NOT carry the binary content.
 */
public class AttachmentInfo {
    private String attachmentId;
    private String name;
    private String contentType;
    private String odataType;
    private boolean file;

    public AttachmentInfo() {}

    public AttachmentInfo(String attachmentId, String name, String contentType,
                          String odataType, boolean file) {
        this.attachmentId = attachmentId;
        this.name = name;
        this.contentType = contentType;
        this.odataType = odataType;
        this.file = file;
    }

    public String getAttachmentId() { return attachmentId; }
    public void setAttachmentId(String attachmentId) { this.attachmentId = attachmentId; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getContentType() { return contentType; }
    public void setContentType(String contentType) { this.contentType = contentType; }

    public String getOdataType() { return odataType; }
    public void setOdataType(String odataType) { this.odataType = odataType; }

    public boolean isFile() { return file; }
    public void setFile(boolean file) { this.file = file; }
}
