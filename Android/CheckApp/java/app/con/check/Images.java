package app.con.check;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import android.widget.ImageView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class Images {
    private Images() {}

    private static final LruCache<String, Bitmap> kept = new LruCache<String, Bitmap>(48 * 1024 * 1024) {
        @Override protected int sizeOf(String key, Bitmap picture) { return picture.getByteCount(); }
    };
    private static final ExecutorService loaders = Executors.newFixedThreadPool(4);
    private static final int MOST_BYTES = 16 * 1024 * 1024;
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static final Map<ImageView, String> wanted = new WeakHashMap<>();
    private static final Map<String, java.util.List<Runnable>> pending = new HashMap<>();

    static void show(ImageView view, String address, int maxPixels) {
        String key = address == null ? null : address + "|" + maxPixels;
        if (key != null && key.equals(wanted.get(view)) && view.getDrawable() != null) return;
        wanted.put(view, key);
        view.setImageDrawable(null);
        if (key == null) return;
        Bitmap ready = kept.get(key);
        if (ready != null) { view.setImageBitmap(ready); return; }
        Runnable land = () -> {
            Bitmap picture = kept.get(key);
            if (picture != null && key.equals(wanted.get(view))) {
                view.setImageBitmap(picture);
                view.setAlpha(0f);
                view.animate().alpha(1f).setDuration(160).start();
            }
        };
        java.util.List<Runnable> waiting = pending.get(key);
        if (waiting != null) { waiting.add(land); return; }
        waiting = new java.util.ArrayList<>();
        waiting.add(land);
        pending.put(key, waiting);
        loaders.execute(() -> {
            Bitmap picture = load(address, maxPixels);
            main.post(() -> {
                if (picture != null) kept.put(key, picture);
                java.util.List<Runnable> told = pending.remove(key);
                if (told != null) for (Runnable one : told) one.run();
            });
        });
    }

    private static Bitmap load(String address, int maxPixels) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL(address);
            if (!"https".equals(url.getProtocol())) return null;
            connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(20000);
            if (connection.getResponseCode() / 100 != 2) return null;
            long length = connection.getContentLengthLong();
            if (length > MOST_BYTES) return null;
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(length > 0 ? (int) length : 65536);
            try (InputStream in = connection.getInputStream()) {
                byte[] chunk = new byte[16384];
                for (int read; (read = in.read(chunk)) > 0; ) {
                    if (bytes.size() + read > MOST_BYTES) return null;
                    bytes.write(chunk, 0, read);
                }
            }
            byte[] data = bytes.toByteArray();
            BitmapFactory.Options size = new BitmapFactory.Options();
            size.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(data, 0, data.length, size);
            BitmapFactory.Options decode = new BitmapFactory.Options();
            decode.inSampleSize = 1;
            while (Math.max(size.outWidth, size.outHeight) / (decode.inSampleSize * 2) >= maxPixels) decode.inSampleSize *= 2;
            Bitmap picture = BitmapFactory.decodeByteArray(data, 0, data.length, decode);
            if (picture == null) return null;
            int longest = Math.max(picture.getWidth(), picture.getHeight());
            if (longest > maxPixels) {
                float scale = maxPixels / (float) longest;
                Bitmap smaller = Bitmap.createScaledBitmap(picture, Math.round(picture.getWidth() * scale), Math.round(picture.getHeight() * scale), true);
                if (smaller != picture) picture.recycle();
                picture = smaller;
            }
            return picture;
        } catch (Exception failed) {
            return null;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }
}
