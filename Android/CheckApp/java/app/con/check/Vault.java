package app.con.check;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.Key;
import java.security.KeyStore;
import java.security.MessageDigest;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class Vault {
    private static final String KEY = "con.credentials";
    private final File folder;

    Vault(Context context) {
        folder = new File(context.getFilesDir(), "credentials");
    }

    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        Key existing = store.getKey(KEY, null);
        if (existing instanceof SecretKey) return (SecretKey) existing;
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build());
        return generator.generateKey();
    }

    private File file(String name) throws Exception {
        StringBuilder digest = new StringBuilder();
        for (byte part : MessageDigest.getInstance("SHA-256").digest(name.getBytes(StandardCharsets.UTF_8))) digest.append(String.format("%02x", part));
        return new File(folder, digest + ".bin");
    }

    synchronized byte[] read(String name) throws Exception {
        File file = file(name);
        if (!file.exists()) return null;
        byte[] stored = Files.readAllBytes(file.toPath());
        if (stored.length < 13) throw new IllegalStateException("record is too short");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, stored, 0, 12));
        return cipher.doFinal(stored, 12, stored.length - 12);
    }

    synchronized void write(String name, byte[] record) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        byte[] nonce = cipher.getIV(), sealed = cipher.doFinal(record);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IllegalStateException("could not create the records folder");
        File file = file(name), fresh = new File(folder, file.getName() + ".new");
        try (FileOutputStream out = new FileOutputStream(fresh)) {
            out.write(nonce);
            out.write(sealed);
        }
        if (!fresh.renameTo(file)) throw new IllegalStateException("could not replace the record file");
    }

    synchronized void remove(String name) throws Exception {
        File file = file(name);
        if (file.exists() && !file.delete()) throw new IllegalStateException("could not remove the record file");
    }
}
