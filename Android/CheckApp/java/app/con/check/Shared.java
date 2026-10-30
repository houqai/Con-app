package app.con.check;

import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

final class Shared {
    static { System.loadLibrary("ConShared"); }
    private Shared() {}

    private static final Handler main = new Handler(Looper.getMainLooper());
    private static Context app;
    private static Vault vault;
    static Runnable onChange, onStream;
    static java.util.function.Consumer<String> onActivate;
    static boolean awake;
    static Runnable onAwake;
    static int certificates;

    static void begin(Context context) {
        if (app != null) return;
        app = context.getApplicationContext();
        vault = new Vault(app);
        certificates = start(app.getFilesDir().getPath(), app.getCacheDir().getPath());
    }

    private static native int start(String files, String caches);
    private static native byte[] text(String english, String language);
    private static native byte[] state();
    private static native void act(byte[] name, byte[] value);
    private static native byte[] ask(byte[] name, byte[] value);
    static native void loginFinished(String address, String sentSecurely, String sentPlainly);
    static native void loginClosed();
    static native void surface(android.view.Surface surface);
    static native void pad(int buttons, float l2, float r2, float leftX, float leftY, float rightX, float rightY);
    static native void padGone();
    private static native byte[] touch(int action, int finger, float x, float y, float width, float height, float left, float right);
    static String touch(int action, int finger, double x, double y, double width, double height, double left, double right) {
        return new String(touch(action, finger, (float) x, (float) y, (float) width, (float) height, (float) left, (float) right), StandardCharsets.UTF_8);
    }
    static native boolean storeCheck();

    static void act(String name, String value) {
        act(name.getBytes(StandardCharsets.UTF_8), (value == null ? "" : value).getBytes(StandardCharsets.UTF_8));
    }
    static void act(String name) { act(name, ""); }
    static String ask(String name, String value) {
        return new String(ask(name.getBytes(StandardCharsets.UTF_8), value.getBytes(StandardCharsets.UTF_8)), StandardCharsets.UTF_8);
    }
    static String word(String english, String language) { return new String(text(english, language), StandardCharsets.UTF_8); }
    static String picture() { return new String(state(), StandardCharsets.UTF_8); }
    static JSONObject now() {
        try { return new JSONObject(picture()); } catch (Exception broken) { return new JSONObject(); }
    }

    static byte[] storeRead(String name) throws Exception { return vault.read(name); }

    static boolean storeWrite(String name, byte[] record) {
        try { vault.write(name, record); return true; } catch (Exception error) { Log.e(MainActivity.TAG, "storage: " + error); return false; }
    }

    static boolean storeRemove(String name) {
        try { vault.remove(name); return true; } catch (Exception error) { Log.e(MainActivity.TAG, "storage: " + error); return false; }
    }

    static void openLogin(String address, String scheme) {
        main.post(() -> app.startActivity(new Intent(app, LoginActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LoginActivity.ADDRESS, address).putExtra(LoginActivity.SCHEME, scheme)));
    }

    static void closeLogin() { main.post(LoginActivity::closeOpen); }

    static void changed() { main.post(() -> { if (onChange != null) onChange.run(); if (onStream != null) onStream.run(); }); }

    static void keepAwake(boolean on) { main.post(() -> { awake = on; if (onAwake != null) onAwake.run(); }); }

    static void activate(String target) { main.post(() -> { if (onActivate != null) onActivate.accept(target); }); }
}
