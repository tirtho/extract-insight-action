package com.core.az;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.models.BlobStorageException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * Provides read and write/replace operations for blobs in an Azure Storage container.
 *
 * <p>Uses {@link AzConnection} to obtain the authenticated
 * {@link BlobContainerClient} (endpoint and container name are sourced
 * from Key Vault via {@code StorageEndpoint} and {@code StorageContainerName}).</p>
 */
public class AzStorageBlob {

    private static final Logger LOG = LoggerFactory.getLogger(AzStorageBlob.class);

    private final BlobContainerClient containerClient;

    /**
     * Creates a new AzStorageBlob backed by the container configured in Key Vault.
     *
     * @param connection an {@link AzConnection} that supplies the blob container client
     */
    public AzStorageBlob(AzConnection connection) {
        this.containerClient = connection.getStorageBlobContainerClient();
        LOG.info("AzStorageBlob initialised – container: {}", containerClient.getBlobContainerName());
    }

    // ---------------------------------------------------------------
    //  Read operations
    // ---------------------------------------------------------------

    /**
     * Reads a blob's content as a UTF-8 string.
     *
     * @param blobName the blob path/name inside the container
     * @return the blob content as a string
     * @throws BlobStorageException if the blob does not exist or cannot be read
     */
    public String readString(String blobName) {
        LOG.info("Reading blob '{}' as string", blobName);
        byte[] data = readBytes(blobName);
        String content = new String(data, StandardCharsets.UTF_8);
        LOG.info("Blob '{}' read successfully ({} chars)", blobName, content.length());
        return content;
    }

    /**
     * Reads a blob's content as a byte array.
     *
     * @param blobName the blob path/name inside the container
     * @return the blob content as bytes
     * @throws BlobStorageException if the blob does not exist or cannot be read
     */
    public byte[] readBytes(String blobName) {
        LOG.info("Reading blob '{}' as bytes", blobName);
        BlobClient blobClient = containerClient.getBlobClient(blobName);
        ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
        blobClient.downloadStream(outputStream);
        byte[] data = outputStream.toByteArray();
        LOG.info("Blob '{}' read successfully ({} bytes)", blobName, data.length);
        return data;
    }

    /**
     * Opens an input stream to a blob for streaming reads.
     *
     * @param blobName the blob path/name inside the container
     * @return an {@link InputStream} over the blob content
     * @throws BlobStorageException if the blob does not exist or cannot be read
     */
    public InputStream readStream(String blobName) {
        LOG.info("Opening stream for blob '{}'", blobName);
        BlobClient blobClient = containerClient.getBlobClient(blobName);
        return blobClient.openInputStream();
    }

    // ---------------------------------------------------------------
    //  Write / replace operations
    // ---------------------------------------------------------------

    /**
     * Writes (or replaces) a blob with UTF-8 string content.
     * If the blob already exists it is overwritten.
     *
     * @param blobName the blob path/name inside the container
     * @param content  the string content to upload
     */
    public void writeString(String blobName, String content) {
        LOG.info("Writing blob '{}' ({} chars)", blobName, content.length());
        writeBytes(blobName, content.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * Writes (or replaces) a blob with byte array content.
     * If the blob already exists it is overwritten.
     *
     * @param blobName the blob path/name inside the container
     * @param data     the byte content to upload
     */
    public void writeBytes(String blobName, byte[] data) {
        LOG.info("Writing blob '{}' ({} bytes)", blobName, data.length);
        BlobClient blobClient = containerClient.getBlobClient(blobName);
        blobClient.upload(new ByteArrayInputStream(data), data.length, true);
        LOG.info("Blob '{}' written successfully", blobName);
    }

    /**
     * Writes (or replaces) a blob from an input stream.
     * If the blob already exists it is overwritten.
     *
     * @param blobName    the blob path/name inside the container
     * @param inputStream the content to upload
     * @param length      the number of bytes in the stream
     */
    public void writeStream(String blobName, InputStream inputStream, long length) {
        LOG.info("Writing blob '{}' from stream ({} bytes)", blobName, length);
        BlobClient blobClient = containerClient.getBlobClient(blobName);
        blobClient.upload(inputStream, length, true);
        LOG.info("Blob '{}' written successfully", blobName);
    }

    // ---------------------------------------------------------------
    //  Utility operations
    // ---------------------------------------------------------------

    /**
     * Checks whether a blob exists in the container.
     *
     * @param blobName the blob path/name inside the container
     * @return {@code true} if the blob exists, {@code false} otherwise
     */
    public boolean exists(String blobName) {
        return containerClient.getBlobClient(blobName).exists();
    }

    /**
     * Returns the full URL for a blob in the container.
     *
     * @param blobName the blob path/name inside the container
     * @return the absolute URL to the blob
     */
    public String getBlobUrl(String blobName) {
        return containerClient.getBlobClient(blobName).getBlobUrl();
    }

    /**
     * Deletes a blob if it exists.
     *
     * @param blobName the blob path/name inside the container
     * @return {@code true} if the blob was deleted, {@code false} if it did not exist
     */
    public boolean delete(String blobName) {
        LOG.info("Deleting blob '{}'", blobName);
        BlobClient blobClient = containerClient.getBlobClient(blobName);
        return blobClient.deleteIfExists();
    }
}
