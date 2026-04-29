package com.eia.ui.model;

public record EmailSummaryView(
        String id,
        String subject,
        String fromName,
        String fromAddress,
        String receivedDateTime,
        String extractedAt,
        int attachmentCount
) {
}