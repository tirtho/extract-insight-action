package com.core.az;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.specialized.BlobInputStream;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class AzStorageBlobTest {

    private static final String CONTAINER_NAME = "test-container";
    private static final String BLOB_NAME = "folder/test-file.txt";
    private static final String BLOB_CONTENT = "Hello, Azure Storage!";

    @Mock
    private AzConnection mockConnection;

    @Mock
    private BlobContainerClient mockContainerClient;

    @Mock
    private BlobClient mockBlobClient;

    private AzStorageBlob storageBlob;

    @BeforeEach
    void setUp() {
        when(mockContainerClient.getBlobContainerName()).thenReturn(CONTAINER_NAME);
        when(mockConnection.getStorageBlobContainerClient()).thenReturn(mockContainerClient);
        when(mockContainerClient.getBlobClient(BLOB_NAME)).thenReturn(mockBlobClient);

        storageBlob = new AzStorageBlob(mockConnection);
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    @Test
    void constructor_getsContainerClientFromConnection() {
        verify(mockConnection).getStorageBlobContainerClient();
    }

    // ---------------------------------------------------------------
    //  readString
    // ---------------------------------------------------------------

    @Test
    void readString_returnsUtf8Content() {
        byte[] bytes = BLOB_CONTENT.getBytes(StandardCharsets.UTF_8);
        doAnswer(invocation -> {
            OutputStream out = invocation.getArgument(0);
            out.write(bytes);
            return null;
        }).when(mockBlobClient).downloadStream(any(OutputStream.class));

        String result = storageBlob.readString(BLOB_NAME);

        assertEquals(BLOB_CONTENT, result);
        verify(mockBlobClient).downloadStream(any(OutputStream.class));
    }

    // ---------------------------------------------------------------
    //  readBytes
    // ---------------------------------------------------------------

    @Test
    void readBytes_returnsDownloadedBytes() {
        byte[] expected = new byte[]{1, 2, 3, 4, 5};
        doAnswer(invocation -> {
            OutputStream out = invocation.getArgument(0);
            out.write(expected);
            return null;
        }).when(mockBlobClient).downloadStream(any(OutputStream.class));

        byte[] result = storageBlob.readBytes(BLOB_NAME);

        assertArrayEquals(expected, result);
    }

    @Test
    void readBytes_emptyBlob_returnsEmptyArray() {
        // downloadStream writes nothing
        doNothing().when(mockBlobClient).downloadStream(any(OutputStream.class));

        byte[] result = storageBlob.readBytes(BLOB_NAME);

        assertEquals(0, result.length);
    }

    // ---------------------------------------------------------------
    //  readStream
    // ---------------------------------------------------------------

    @Test
    void readStream_returnsInputStreamFromBlobClient() {
        BlobInputStream mockInputStream = mock(BlobInputStream.class);
        when(mockBlobClient.openInputStream()).thenReturn(mockInputStream);

        InputStream result = storageBlob.readStream(BLOB_NAME);

        assertSame(mockInputStream, result);
        verify(mockBlobClient).openInputStream();
    }

    // ---------------------------------------------------------------
    //  writeString
    // ---------------------------------------------------------------

    @Test
    void writeString_uploadsUtf8Bytes() {
        storageBlob.writeString(BLOB_NAME, BLOB_CONTENT);

        ArgumentCaptor<InputStream> streamCaptor = ArgumentCaptor.forClass(InputStream.class);
        ArgumentCaptor<Long> lengthCaptor = ArgumentCaptor.forClass(Long.class);

        verify(mockBlobClient).upload(streamCaptor.capture(), lengthCaptor.capture(), eq(true));

        byte[] expectedBytes = BLOB_CONTENT.getBytes(StandardCharsets.UTF_8);
        assertEquals(expectedBytes.length, lengthCaptor.getValue().intValue());
    }

    // ---------------------------------------------------------------
    //  writeBytes
    // ---------------------------------------------------------------

    @Test
    void writeBytes_uploadsWithOverwrite() {
        byte[] data = {10, 20, 30};

        storageBlob.writeBytes(BLOB_NAME, data);

        verify(mockBlobClient).upload(any(ByteArrayInputStream.class), eq((long) data.length), eq(true));
    }

    // ---------------------------------------------------------------
    //  writeStream
    // ---------------------------------------------------------------

    @Test
    void writeStream_uploadsStreamWithOverwrite() {
        InputStream stream = new ByteArrayInputStream(new byte[]{1, 2});
        long length = 2L;

        storageBlob.writeStream(BLOB_NAME, stream, length);

        verify(mockBlobClient).upload(same(stream), eq(length), eq(true));
    }

    // ---------------------------------------------------------------
    //  exists
    // ---------------------------------------------------------------

    @Test
    void exists_returnsTrue_whenBlobExists() {
        when(mockBlobClient.exists()).thenReturn(true);

        assertTrue(storageBlob.exists(BLOB_NAME));
    }

    @Test
    void exists_returnsFalse_whenBlobDoesNotExist() {
        when(mockBlobClient.exists()).thenReturn(false);

        assertFalse(storageBlob.exists(BLOB_NAME));
    }

    // ---------------------------------------------------------------
    //  delete
    // ---------------------------------------------------------------

    @Test
    void delete_returnsTrue_whenBlobDeleted() {
        when(mockBlobClient.deleteIfExists()).thenReturn(true);

        assertTrue(storageBlob.delete(BLOB_NAME));
        verify(mockBlobClient).deleteIfExists();
    }

    @Test
    void delete_returnsFalse_whenBlobDidNotExist() {
        when(mockBlobClient.deleteIfExists()).thenReturn(false);

        assertFalse(storageBlob.delete(BLOB_NAME));
    }

    // ---------------------------------------------------------------
    //  Different blob names
    // ---------------------------------------------------------------

    @Test
    void operations_useDifferentBlobNames() {
        String otherName = "other/path.json";
        BlobClient otherBlobClient = mock(BlobClient.class);
        when(mockContainerClient.getBlobClient(otherName)).thenReturn(otherBlobClient);
        when(otherBlobClient.exists()).thenReturn(true);

        assertTrue(storageBlob.exists(otherName));
        verify(mockContainerClient).getBlobClient(otherName);
        verify(otherBlobClient).exists();
    }
}
