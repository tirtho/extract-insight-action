package com.eia.ui.model;

public record AttachmentView(
        String id,
        String attachmentName,
        String contentType,
        String status,
        String analyzerName,
        String blobUrl,
        String createdAt,
        String analyzeOperationId,
        String analyzeResult,
        String errorMessage
) {
}