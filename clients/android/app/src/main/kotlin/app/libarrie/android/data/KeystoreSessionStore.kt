package app.libarrie.android.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import app.libarrie.core.auth.SessionStore
import app.libarrie.core.auth.StoredSession
import kotlinx.serialization.json.Json
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The session (tokens included), AES-GCM encrypted with a key held in the
 * Android Keystore. The file is in no_backup and the key never leaves the
 * device, so backups and device transfers never carry usable tokens; after
 * a restore the user signs in again.
 */
class KeystoreSessionStore(private val file: File) : SessionStore {
    private val alias = "libarrie-session"
    private val json = Json { ignoreUnknownKeys = true }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    @Synchronized
    override fun load(): StoredSession? {
        if (!file.isFile) return null
        return runCatching {
            val bytes = file.readBytes()
            val iv = bytes.copyOfRange(0, 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            json.decodeFromString<StoredSession>(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size))))
        }.getOrElse {
            // Unreadable (for example restored without its key): start over.
            file.delete()
            null
        }
    }

    @Synchronized
    override fun save(session: StoredSession) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(json.encodeToString(StoredSession.serializer(), session).toByteArray())
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, ".${file.name}.tmp")
        temporary.writeBytes(sealed)
        temporary.renameTo(file)
    }

    @Synchronized
    override fun clear() { file.delete() }
}
