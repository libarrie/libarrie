package app.libarrie.android.data

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import androidx.exifinterface.media.ExifInterface
import app.libarrie.core.queue.PreparedImage
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer

class ImagePreparationException(message: String) : Exception(message)

/**
 * Prepares captured or imported photos (sections 6 and 7):
 *
 * - JPEG and PNG keep their exact bytes when nothing must change.
 * - HEIC/HEIF and other formats are decoded with the platform's own
 *   decoder (ImageDecoder) and saved as JPEG; nothing is bundled.
 * - GPS location is removed by default (a lossless EXIF rewrite for JPEG);
 *   orientation and other metadata are kept.
 * - Images over the server's byte limit are re-encoded smaller, never below
 *   1,600 px on the long side, so handwriting stays legible.
 */
class ImagePreparer(private val keepLocation: Boolean, private val maxBytes: Int, private val scratch: File) {

    fun prepare(input: ByteArray): PreparedImage {
        val type = sniff(input) ?: decodeTypeOrNull(input) ?: throw unreadable()
        var bytes: ByteArray
        var contentType: String
        if (type == "image/jpeg" || type == "image/png") {
            bytes = if (type == "image/jpeg" && !keepLocation) stripLocation(input) else input
            contentType = type
        } else {
            bytes = encodeJpeg(decode(input, null), 90)
            contentType = "image/jpeg"
        }
        if (bytes.size > maxBytes) {
            var quality = 85
            var bitmap = decode(input, null)
            var longest = maxOf(bitmap.width, bitmap.height)
            while (true) {
                bytes = encodeJpeg(bitmap, quality)
                contentType = "image/jpeg"
                if (bytes.size <= maxBytes) break
                if (quality > 70) {
                    quality -= 10
                } else {
                    longest = longest * 3 / 4
                    if (longest < 1600) throw ImagePreparationException("This photo is too large to upload, even after resizing.")
                    bitmap = decode(input, longest)
                }
            }
        }
        return PreparedImage(bytes, contentType)
    }

    private fun unreadable() = ImagePreparationException("This photo could not be read. Try a JPEG or PNG, or take the photo again.")

    private fun sniff(bytes: ByteArray): String? = when {
        bytes.size > 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte() -> "image/jpeg"
        bytes.size > 8 && bytes.copyOfRange(0, 8).contentEquals(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) -> "image/png"
        else -> null
    }

    private fun decodeTypeOrNull(bytes: ByteArray): String? = runCatching {
        var mime: String? = null
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            mime = info.mimeType
            decoder.setTargetSize(1, 1)
        }
        mime
    }.getOrNull()

    /** Decoded with orientation applied (ImageDecoder honors EXIF), optionally downscaled. */
    private fun decode(bytes: ByteArray, maxDimension: Int?): Bitmap = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            if (maxDimension != null) {
                val longest = maxOf(info.size.width, info.size.height)
                if (longest > maxDimension) {
                    val scale = maxDimension.toDouble() / longest
                    decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
                }
            }
        }
    } catch (e: Exception) {
        throw unreadable()
    }

    private fun encodeJpeg(bitmap: Bitmap, quality: Int): ByteArray =
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            out.toByteArray()
        }

    /** Lossless: rewrites only the EXIF block, leaving the pixels untouched. */
    private fun stripLocation(jpeg: ByteArray): ByteArray {
        val file = File.createTempFile("strip", ".jpg", scratch)
        try {
            file.writeBytes(jpeg)
            val exif = ExifInterface(file)
            if (exif.latLong == null && exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE) == null) return jpeg
            for (tag in GPS_TAGS) exif.setAttribute(tag, null)
            exif.saveAttributes()
            return file.readBytes()
        } finally {
            file.delete()
        }
    }

    companion object {
        private val GPS_TAGS = listOf(
            ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF,
            ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
            ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
            ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
            ExifInterface.TAG_GPS_PROCESSING_METHOD, ExifInterface.TAG_GPS_AREA_INFORMATION,
            ExifInterface.TAG_GPS_SPEED, ExifInterface.TAG_GPS_SPEED_REF,
            ExifInterface.TAG_GPS_IMG_DIRECTION, ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
            ExifInterface.TAG_GPS_DEST_LATITUDE, ExifInterface.TAG_GPS_DEST_LONGITUDE,
            ExifInterface.TAG_GPS_DEST_BEARING, ExifInterface.TAG_GPS_TRACK,
            ExifInterface.TAG_GPS_SATELLITES, ExifInterface.TAG_GPS_MAP_DATUM,
            ExifInterface.TAG_GPS_VERSION_ID, ExifInterface.TAG_GPS_H_POSITIONING_ERROR,
        )
    }
}
