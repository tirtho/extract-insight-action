package com.core.az;

import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.models.EmbeddingItem;
import com.azure.ai.openai.models.Embeddings;
import com.azure.ai.openai.models.EmbeddingsOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Helper class for generating embeddings using Azure OpenAI.
 * Provides methods to embed single or batch text content for vector search capabilities.
 */
public class AzOpenAiEmbeddings {

    private static final Logger LOG = LoggerFactory.getLogger(AzOpenAiEmbeddings.class);

    private final OpenAIClient openAIClient;
    private final String deploymentName;

    /**
     * Constructs an AzOpenAiEmbeddings instance.
     *
     * @param openAIClient The OpenAIClient configured with endpoint and credentials
     * @param deploymentName The deployment name for the embeddings model (e.g., "text-embedding-3-small")
     */
    public AzOpenAiEmbeddings(OpenAIClient openAIClient, String deploymentName) {
        this.openAIClient = openAIClient;
        this.deploymentName = deploymentName;
    }

    /**
     * Generates an embedding vector for a single text input.
     * Suitable for embedding email bodies or attachment analysis results.
     *
     * @param text The text to embed (e.g., email body or extracted attachment content)
     * @return A List<Float> representing the embedding vector
     * @throws IllegalArgumentException if text is null or empty
     * @throws RuntimeException if the API call fails
     */
    public List<Double> embedText(String text) {
        if (text == null || text.trim().isEmpty()) {
            throw new IllegalArgumentException("Text to embed cannot be null or empty");
        }

        try {
            LOG.info("Generating embedding for text of length: {}", text.length());

            EmbeddingsOptions embeddingsOptions = new EmbeddingsOptions(List.of(text))
                    .setModel(deploymentName);

            Embeddings embeddings = openAIClient.getEmbeddings(deploymentName, embeddingsOptions);

            if (embeddings == null || embeddings.getData() == null || embeddings.getData().isEmpty()) {
                throw new RuntimeException("No embedding data returned from API");
            }

            EmbeddingItem item = embeddings.getData().get(0);
            List<Double> result = toDoubleVector(item);

            LOG.info("Embedding generated successfully. Vector dimension: {}", result.size());
            return result;

        } catch (Exception e) {
            LOG.error("Failed to generate embedding: {}", e.getMessage(), e);
            throw new RuntimeException("Failed to generate embedding: " + e.getMessage(), e);
        }
    }

    /**
     * Generates embeddings for multiple text inputs in batch.
     * More efficient than calling embedText() multiple times for large batches.
     *
     * @param texts A list of text strings to embed
     * @return A list of embedding vectors, with same size as input texts
     * @throws IllegalArgumentException if texts is null or empty
     * @throws RuntimeException if the API call fails
     */
    public List<List<Double>> embedTexts(List<String> texts) {
        if (texts == null || texts.isEmpty()) {
            throw new IllegalArgumentException("Texts list cannot be null or empty");
        }

        try {
            LOG.info("Generating embeddings for batch of {} texts", texts.size());

            EmbeddingsOptions embeddingsOptions = new EmbeddingsOptions(texts)
                    .setModel(deploymentName);

            Embeddings embeddings = openAIClient.getEmbeddings(deploymentName, embeddingsOptions);

            if (embeddings == null || embeddings.getData() == null) {
                throw new RuntimeException("No embedding data returned from API");
            }

            List<List<Double>> results = new ArrayList<>();
            for (EmbeddingItem item : embeddings.getData()) {
                results.add(toDoubleVector(item));
            }

            LOG.info("Batch embedding generated successfully. Count: {}", results.size());
            return results;

        } catch (Exception e) {
            LOG.error("Failed to generate batch embeddings: {}", e.getMessage(), e);
            throw new RuntimeException("Failed to generate batch embeddings: " + e.getMessage(), e);
        }
    }

    /**
     * Truncates text to a reasonable length to avoid excessive API costs and timeouts.
     * Embeddings APIs typically handle up to 2048 tokens per request.
     * This method uses a conservative estimate of ~4 characters per token.
     *
     * @param text The text to truncate
     * @param maxCharacters Maximum number of characters to keep (default: 8000 chars ≈ 2000 tokens)
     * @return Truncated text
     */
    public static String truncateForEmbedding(String text, int maxCharacters) {
        if (text == null || text.length() <= maxCharacters) {
            return text;
        }
        return text.substring(0, maxCharacters);
    }

    /**
     * Convenience method: truncates to default 8000 characters.
     */
    public static String truncateForEmbedding(String text) {
        return truncateForEmbedding(text, 8000);
    }

    // The SDK returns List<Float>; Cosmos vector properties are persisted as doubles.
    private static List<Double> toDoubleVector(EmbeddingItem item) {
        return item.getEmbedding().stream()
                .map(Float::doubleValue)
                .collect(Collectors.toList());
    }
}
