package com.eia.ui.model;

import java.util.List;

public record EmailDetailView(
        String id,
        String subject,
        String fromName,
        String fromAddress,
        String receivedDateTime,
        String extractedAt,
        String bodyPreview,        String bodyContent,        List<AttachmentView> attachments
) {
}