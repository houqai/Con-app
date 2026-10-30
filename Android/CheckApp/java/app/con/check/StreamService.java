package app.con.check;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

public final class StreamService extends Service {
    private static final String CHANNEL = "stream", LEAVE = "app.con.check.leave";
    private static final String TITLE = "title", TEXT = "text", BUTTON = "button";
    private static boolean running;

    static void begin(Context context, String title, String text, String button) {
        if (running) return;
        Intent start = new Intent(context, StreamService.class).putExtra(TITLE, title).putExtra(TEXT, text).putExtra(BUTTON, button);
        try {
            context.startForegroundService(start);
            running = true;
        } catch (Exception refused) {
            Log.e(MainActivity.TAG, "stream: cannot keep running in background: " + refused);
        }
    }

    static void end(Context context) {
        if (!running) return;
        running = false;
        context.stopService(new Intent(context, StreamService.class));
    }

    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent != null && LEAVE.equals(intent.getAction())) {
            Log.i(MainActivity.TAG, "stream: left (the notification)");
            Shared.act("cancelLaunch");
            running = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel(CHANNEL, "Con", NotificationManager.IMPORTANCE_LOW));
        String title = intent == null ? "Con" : intent.getStringExtra(TITLE), text = intent == null ? "" : intent.getStringExtra(TEXT);
        String button = intent == null ? "" : intent.getStringExtra(BUTTON);
        Intent back = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (back != null) back.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        PendingIntent open = PendingIntent.getActivity(this, 0, back, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent leave = PendingIntent.getService(this, 1, new Intent(this, StreamService.class).setAction(LEAVE), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .addAction(new Notification.Action.Builder(null, button, leave).build())
                .build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        else startForeground(1, notification);
        return START_NOT_STICKY;
    }

    @Override public void onTaskRemoved(Intent rootIntent) {
        Log.i(MainActivity.TAG, "stream: left (the app was closed)");
        Shared.act("cancelLaunch");
        running = false;
        stopSelf();
    }

    @Override public void onDestroy() { running = false; super.onDestroy(); }

    @Override public IBinder onBind(Intent intent) { return null; }
}
