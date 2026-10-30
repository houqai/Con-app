package app.con.check;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RenderEffect;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.hardware.input.InputManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

public final class StreamActivity extends Activity implements SurfaceHolder.Callback, InputManager.InputDeviceListener {
    private static final String TAG = MainActivity.TAG;
    private final Pad pad = new Pad();
    private final Handler main = new Handler(Looper.getMainLooper());
    private JSONObject state = new JSONObject(), texts = new JSONObject();
    private FrameLayout root, cover, menuLayer, trophyLayer;
    private SurfaceView picture;
    private LinearLayout waiting, bar, controls, panel;
    private TextView waitingText;
    private Look.Icon statsButton, padButton;
    private TouchPadView touchPad;
    private boolean serviceAsked;
    private android.net.wifi.WifiManager.WifiLock quickWifi;
    private String logged = "", drawnCover = "", drawnMenu = "", drawnPanel = "", drawnTrophy = "";
    private long panelLogged;
    private boolean up, over, sessionAsked, controlsShown = true, fill;
    private int insetLeft, insetTop;
    private final Runnable hide = () -> { controlsShown = false; show(); };

    @Override protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Look.density = getResources().getDisplayMetrics().density;
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        picture = new SurfaceView(this);
        root.addView(picture, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        touchPad = new TouchPadView(this, this::reveal);
        touchPad.setVisibility(View.GONE);
        root.addView(touchPad, Look.whole());
        waiting = Look.column(this, 14);
        waiting.setGravity(Gravity.CENTER);
        ProgressBar wheel = new ProgressBar(this);
        wheel.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(Color.WHITE));
        waiting.addView(wheel, Look.sized(40, 40));
        waitingText = Look.text(this, "", 13, 400, Look.white(0.85));
        waiting.addView(waitingText);
        root.addView(waiting, Look.at(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        bar = Look.row(this, 8);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(bar, Look.at(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.START));
        controls = buildControls();
        bar.addView(controls, Look.wrap());
        panel = Look.row(this, 12);
        bar.addView(panel, Look.wrap());
        cover = new FrameLayout(this);
        root.addView(cover, Look.whole());
        trophyLayer = new FrameLayout(this);
        root.addView(trophyLayer, Look.whole());
        menuLayer = new FrameLayout(this);
        root.addView(menuLayer, Look.whole());
        setContentView(root);
        root.setOnClickListener(view -> reveal());
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            insetLeft = Math.max(insets.getSystemWindowInsetLeft(), insets.getDisplayCutout() == null ? 0 : insets.getDisplayCutout().getSafeInsetLeft());
            insetTop = insets.getDisplayCutout() == null ? 0 : insets.getDisplayCutout().getSafeInsetTop();
            bar.setPadding(Look.dp(12) + insetLeft, Look.dp(12) + insetTop, Look.dp(12), 0);
            int insetRight = Math.max(insets.getSystemWindowInsetRight(), insets.getDisplayCutout() == null ? 0 : insets.getDisplayCutout().getSafeInsetRight());
            touchPad.edges(insetLeft, insetRight);
            return insets;
        });
        root.addOnLayoutChangeListener((view, left, top, right, bottom, a, b, c, d) -> fitPicture());
        if (Build.VERSION.SDK_INT >= 30) getWindow().getDecorView().post(() -> {
            if (getWindow().getInsetsController() == null) return;
            getWindow().getInsetsController().hide(WindowInsets.Type.systemBars());
            getWindow().getInsetsController().setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        });
        else getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        if (Build.VERSION.SDK_INT >= 28) getWindow().getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        picture.getHolder().addCallback(this);
        ((InputManager) getSystemService(INPUT_SERVICE)).registerInputDeviceListener(this, null);
        Shared.onAwake = this::awake;
        Shared.onStream = this::show;
        awake();
        reveal();
        show();
    }

    private void fitPicture() {
        int width = root.getWidth(), height = root.getHeight();
        if (width == 0 || height == 0) return;
        int pictureWidth = fill ? Math.max(width, height * 16 / 9) : Math.min(width, height * 16 / 9), pictureHeight = pictureWidth * 9 / 16;
        FrameLayout.LayoutParams size = (FrameLayout.LayoutParams) picture.getLayoutParams();
        if (size.width != pictureWidth || size.height != pictureHeight) {
            size.width = pictureWidth; size.height = pictureHeight;
            picture.post(() -> picture.setLayoutParams(size));
        }
    }

    @Override protected void onDestroy() {
        StreamService.end(this);
        if (quickWifi != null && quickWifi.isHeld()) quickWifi.release();
        ((InputManager) getSystemService(INPUT_SERVICE)).unregisterInputDeviceListener(this);
        main.removeCallbacks(hide);
        Shared.onAwake = null;
        Shared.onStream = null;
        super.onDestroy();
    }

    @Override protected void onStop() {
        super.onStop();
        if (!over) Log.i(TAG, "stream: in background, continuing");
        pad.release();
        touchPad.letGo();
    }

    @Override public void onBackPressed() {
        JSONObject menu = state.optJSONObject("menu");
        if (menu != null && menu.optBoolean("open")) { Shared.act("menuClose"); return; }
        leave("back");
    }

    private void leave(String why) {
        if (over) return;
        over = true;
        Log.i(TAG, "stream: left (" + why + ")");
        pad.release();
        touchPad.letGo();
        Shared.act("cancelLaunch");
        StreamService.end(this);
        finish();
    }

    private void awake() {
        if (Shared.awake) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    @Override public void surfaceCreated(SurfaceHolder holder) { Shared.surface(holder.getSurface()); }
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}
    @Override public void surfaceDestroyed(SurfaceHolder holder) { Shared.surface(null); }

    private String t(String key) { return texts.optString(key, key); }

    private void reveal() {
        controlsShown = true;
        main.removeCallbacks(hide);
        main.postDelayed(hide, 3000);
        show();
    }

    private void show() {
        try {
            state = Shared.now();
            if (!state.has("phase")) return;
            texts = state.getJSONObject("t");
            String phase = state.getString("phase");
            boolean connecting = state.getBoolean("connecting"), launching = state.getBoolean("launching") || connecting;
            boolean streaming = phase.equals("streaming"), live = streaming || phase.equals("connecting");
            boolean failedLaunch = !state.isNull("cloudError") && state.getBoolean("launching");
            if (launching || live) up = true;
            boolean nowFill = "fill".equals(state.getJSONObject("settings").optString("fit"));
            if (nowFill != fill) { fill = nowFill; fitPicture(); }
            if (up && !launching && !live && !failedLaunch && !over) { end(phase); return; }
            if (up && !over && !serviceAsked) { serviceAsked = true; keepGoing(); }

            drawCover(!live && (launching || failedLaunch), connecting);
            waiting.setVisibility(phase.equals("connecting") ? View.VISIBLE : View.GONE);
            waitingText.setText(state.isNull("streamStatus") ? t("connecting") : state.getString("streamStatus"));
            boolean controlsVisible = live && (controlsShown || phase.equals("connecting"));
            controls.setVisibility(controlsVisible ? View.VISIBLE : View.GONE);
            boolean statsVisible = state.getBoolean("statsVisible");
            statsButton.set("chart", statsVisible ? Color.WHITE : Look.white(0.75));
            statsButton.setBackground(square(statsVisible));
            statsButton.setContentDescription(statsVisible ? t("statsHide") : t("statsShow"));
            drawPanel(live && statsVisible && !state.isNull("cells"), controlsVisible);
            boolean touchOn = state.getJSONObject("settings").optBoolean("touchGamepad", true);
            boolean padShown = streaming && touchOn && !Pad.connected() && !state.getJSONObject("menu").optBoolean("open");
            touchPad.setVisibility(padShown ? View.VISIBLE : View.GONE);
            padButton.set("gamecontroller", touchOn ? Color.WHITE : Look.white(0.75));
            padButton.setBackground(square(touchOn));
            padButton.setContentDescription(t("touchGamepad"));
            ((FrameLayout.LayoutParams) bar.getLayoutParams()).gravity = Gravity.TOP | (padShown ? Gravity.CENTER_HORIZONTAL : Gravity.START);
            bar.setLayoutParams(bar.getLayoutParams());
            drawTrophy(live, padShown && controlsVisible);
            drawMenu();

            String note = !state.isNull("cloudError") ? state.getString("cloudError")
                    : phase.startsWith("failed: ") ? phase.substring(8)
                    : streaming ? state.optString("panel", "")
                    : !state.isNull("streamStatus") ? state.getString("streamStatus")
                    : !state.isNull("cloudStatus") ? state.getString("cloudStatus")
                    : up && !launching ? "—" : "…";
            if (!sessionAsked && (!phase.equals("idle") || note.equals(Shared.word("Creating the game session…", state.optString("language", "en"))))) {
                sessionAsked = true;
                Log.i(TAG, "stream: session asked of Sony");
            }
            String line = "stream: phase " + (phase.startsWith("failed") ? "failed" : phase) + " launching " + launching + " surface " + state.getBoolean("surface")
                    + (streaming ? "" : " note " + note.replace('\n', ' '));
            if (!line.equals(logged)) { logged = line; Log.i(TAG, line); }
            long now = System.currentTimeMillis();
            if (streaming && !state.isNull("panel") && now - panelLogged >= 5000) { panelLogged = now; Log.i(TAG, "stream: figures drawn " + state.getInt("drawn") + " size " + state.getString("size") + " sound " + state.getInt("sound")
                        + " left out " + state.getInt("soundLeftOut") + " dry " + state.optInt("soundDry") + " heard " + state.optInt("soundHeard") + " peak " + state.optInt("soundPeak")
                        + " frames lost " + state.optInt("framesLost") + " held " + state.optInt("framesHeld")
                        + " hidden " + state.optInt("framesHidden") + " in " + state.optInt("hiddenRuns") + " runs bridged " + state.optInt("framesBridged") + " · " + state.getString("panel")); }
        } catch (Exception error) {
            Log.e(TAG, "FAIL stream " + error, error);
        }
    }

    private void end(String phase) throws Exception {
        over = true;
        String note = !state.isNull("cloudError") ? state.getString("cloudError")
                : phase.startsWith("failed: ") ? phase.substring(8)
                : state.isNull("cloudStatus") ? "—" : state.getString("cloudStatus");
        Log.i(TAG, "stream: phase " + (phase.startsWith("failed") ? "failed" : phase) + " launching false surface " + state.getBoolean("surface") + " note " + note);
        pad.release();
        StreamService.end(this);
        finish();
    }

    private void keepGoing() throws Exception {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            android.content.SharedPreferences kept = getSharedPreferences("check", MODE_PRIVATE);
            if (!kept.getBoolean("notificationsAsked", false)) {
                kept.edit().putBoolean("notificationsAsked", true).apply();
                requestPermissions(new String[] { android.Manifest.permission.POST_NOTIFICATIONS }, 1);
            }
        }
        JSONObject game = state.optJSONObject("launchGame");
        StreamService.begin(this, game == null ? "Con" : game.getString("title"), t("background"), t("leave"));
        try {
            android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
            quickWifi = wifi.createWifiLock(Build.VERSION.SDK_INT >= 29 ? android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY : android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Con stream");
            quickWifi.setReferenceCounted(false);
            quickWifi.acquire();
            Log.i(TAG, "stream: Wi-Fi low-latency lock held");
        } catch (Exception refused) {
            Log.i(TAG, "stream: Wi-Fi lock refused: " + refused);
        }
    }

    private void drawCover(boolean shown, boolean connecting) throws Exception {
        cover.setVisibility(shown ? View.VISIBLE : View.GONE);
        if (!shown) return;
        JSONObject game = state.optJSONObject("launchGame");
        String text = !state.isNull("cloudError") ? state.getString("cloudError") : !state.isNull("cloudStatus") ? state.getString("cloudStatus") : t("checking");
        String focused = Pad.connected() && !state.isNull("focus") ? state.optString("focus") : "";
        String signature = (game == null ? "" : game.optString("id")) + "|" + text + "|" + connecting + "|" + root.getWidth() + "|" + t("cancel") + "|" + focused;
        if (signature.equals(drawnCover)) return;
        drawnCover = signature;
        cover.removeAllViews();
        cover.setClickable(true);
        if (game != null) {
            FrameLayout back = new FrameLayout(this);
            back.setBackgroundColor(game.getInt("backdrop"));
            ImageView spread = new ImageView(this);
            spread.setScaleType(ImageView.ScaleType.CENTER_CROP);
            Images.show(spread, game.isNull("art") ? null : game.getString("art"), Build.VERSION.SDK_INT >= 31 ? 640 : 24);
            if (Build.VERSION.SDK_INT >= 31) spread.setRenderEffect(RenderEffect.createBlurEffect(Look.dp(40), Look.dp(40), Shader.TileMode.CLAMP));
            back.addView(spread, Look.whole());
            cover.addView(back, Look.whole());
        }
        View dim = new View(this);
        dim.setBackgroundColor(Look.faded(Look.CANVAS, 0.82));
        cover.addView(dim, Look.whole());
        int width = Math.round(root.getWidth() / Look.density), height = Math.round(root.getHeight() / Look.density);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout column = Look.column(this, 0);
        column.setGravity(Gravity.CENTER);
        column.setPadding(Look.dp(24), Look.dp(24), Look.dp(24), Look.dp(24));
        if (game != null) {
            int size = Math.max(96, Math.min(220, Math.min(width / 2, height - 260)));
            FrameLayout art = new FrameLayout(this);
            art.setBackground(Look.rounded(game.getInt("tint"), 12));
            ImageView image = new ImageView(this);
            image.setScaleType(ImageView.ScaleType.CENTER_CROP);
            Images.show(image, game.isNull("art") ? null : game.getString("art"), 640);
            art.addView(image, Look.whole());
            Look.round(art, 12);
            art.setElevation(Look.dp(20));
            column.addView(art, Look.sized(size, size));
            TextView title = Look.text(this, game.getString("title"), 28, 600, Look.TEXT);
            title.setGravity(Gravity.CENTER);
            column.addView(title, Look.margins(Look.wrap(), 0, size > 150 ? 34 : 18, 0, 0));
        }
        TextView status = Look.text(this, text, 15, 400, Look.TEXT);
        status.setAlpha(0.7f);
        status.setGravity(Gravity.CENTER);
        status.setMaxWidth(Look.dp(640));
        column.addView(status, Look.margins(Look.wrap(), 0, 12, 0, 0));
        if (connecting) {
            ProgressBar progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
            progress.setIndeterminate(true);
            progress.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(Color.WHITE));
            column.addView(progress, Look.margins(Look.sized(Math.min(320, width - 48), 8), 0, 22, 0, 0));
        }
        LinearLayout buttons = Look.row(this, 14);
        buttons.setGravity(Gravity.CENTER);
        TextView button = Look.quiet(this, connecting ? t("cancel") : t("close"), false);
        if (focused.equals("launch-cancel")) button.setBackground(Look.outlined(Look.white(0.12), 999, Color.WHITE, 3));
        button.setOnClickListener(view -> leave(connecting ? "cancel" : "close"));
        buttons.addView(button, Look.wrap());
        column.addView(buttons, Look.margins(Look.wrap(), 0, 34, 0, 0));
        scroll.addView(column, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        cover.addView(scroll, Look.whole());
    }

    private LinearLayout buildControls() {
        LinearLayout row = Look.row(this, 0);
        row.setPadding(Look.dp(1), 0, Look.dp(1), 0);
        row.setBackground(Look.outlined(Look.black(0.42), 9, Look.white(0.08), 1));
        LinearLayout leave = Look.row(this, 5);
        leave.setPadding(Look.dp(8), 0, Look.dp(8), 0);
        leave.addView(new Look.Icon(this, "xmark", Color.WHITE), Look.sized(9, 9));
        TextView words = Look.text(this, "", 12, 600, Color.WHITE);
        words.setTag("leave");
        leave.addView(words);
        leave.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) view.setBackground(Look.rounded(Look.RED, 6));
            else if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) view.setBackground(null);
            return false;
        });
        leave.setOnClickListener(view -> { Shared.act("leave"); reveal(); });
        row.addView(leave, Look.margins(Look.sized(-2, 24), 2, 0, 0, 0));
        View divider = new View(this);
        divider.setBackgroundColor(Look.white(0.14));
        row.addView(divider, Look.margins(Look.sized(1, 14), 5, 0, 3, 0));
        statsButton = round("chart");
        statsButton.setOnClickListener(view -> { Shared.act("stats"); reveal(); });
        row.addView(statsButton, Look.sized(28, 30));
        padButton = round("gamecontroller");
        padButton.setOnClickListener(view -> {
            JSONObject settings = state.optJSONObject("settings");
            Shared.act("touchGamepad", settings != null && settings.optBoolean("touchGamepad", true) ? "0" : "1");
            reveal();
        });
        row.addView(padButton, Look.sized(28, 30));
        Look.Icon menu = round("menu");
        menu.setOnClickListener(view -> Shared.act("openMenu"));
        row.addView(menu, Look.sized(28, 30));
        return row;
    }

    private Look.Icon round(String icon) {
        Look.Icon button = new Look.Icon(this, icon, Look.white(0.75));
        button.setPadding(Look.dp(7.5), Look.dp(8.5), Look.dp(7.5), Look.dp(8.5));
        Look.pressable(button);
        return button;
    }

    private static InsetDrawable square(boolean on) {
        return new InsetDrawable(Look.rounded(on ? Look.white(0.2) : Color.TRANSPARENT, 6), Look.dp(2), Look.dp(3), Look.dp(2), Look.dp(3));
    }

    private void drawPanel(boolean shown, boolean controlsVisible) throws Exception {
        TextView leaveWords = controls.findViewWithTag("leave");
        if (leaveWords != null) leaveWords.setText(t("leave"));
        panel.setVisibility(shown ? View.VISIBLE : View.GONE);
        if (!shown) return;
        JSONArray details = state.getJSONArray("cells");
        int room = root.getWidth() - insetLeft - Look.dp(24) - (controlsVisible ? controls.getWidth() + Look.dp(8) : 0);
        JSONArray chosen = details.getJSONArray(details.length() - 1);
        for (int index = 0; index < details.length(); index++) if (width(details.getJSONArray(index)) <= room) { chosen = details.getJSONArray(index); break; }
        String signature = chosen.toString();
        if (signature.equals(drawnPanel)) return;
        drawnPanel = signature;
        panel.removeAllViews();
        panel.setPadding(Look.dp(11), 0, Look.dp(11), 0);
        panel.setMinimumHeight(Look.dp(30));
        panel.setBackground(Look.outlined(Look.black(0.42), 9, Look.white(0.08), 1));
        for (int index = 0; index < chosen.length(); index++) {
            JSONObject cell = chosen.getJSONObject(index);
            LinearLayout one = Look.row(this, 4);
            String kind = cell.getString("kind");
            one.addView(new Look.Icon(this, icon(kind), kind.equals("ping") ? cell.getInt("tint") : Look.white(0.5)), Look.sized(11, 11));
            TextView value = Look.line(this, cell.getString("value"), 12, 600, Color.WHITE);
            value.setFontFeatureSettings("tnum");
            one.addView(value);
            if (!cell.isNull("unit")) {
                TextView unit = Look.line(this, cell.getString("unit"), 12, 400, Look.white(0.5));
                unit.setFontFeatureSettings("tnum");
                one.addView(unit);
            }
            panel.addView(one);
        }
        panel.setLayoutParams(Look.sized(-2, 30));
    }

    private static String icon(String kind) {
        switch (kind) {
            case "frames": return "film";
            case "ping": return "wifi";
            case "bitrate": return "arrow.down";
            default: return "tv";
        }
    }

    private int width(JSONArray cells) throws Exception {
        Paint plain = new Paint(), strong = new Paint();
        float size = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 12, getResources().getDisplayMetrics());
        plain.setTextSize(size);
        strong.setTextSize(size);
        strong.setTypeface(Typeface.create(Typeface.DEFAULT, 600, false));
        float total = Look.dp(22);
        for (int index = 0; index < cells.length(); index++) {
            JSONObject cell = cells.getJSONObject(index);
            if (index > 0) total += Look.dp(12);
            total += Look.dp(15) + strong.measureText(cell.getString("value"));
            if (!cell.isNull("unit")) total += plain.measureText(cell.getString("unit")) + Look.dp(4);
        }
        return Math.round(total);
    }

    private void drawTrophy(boolean live, boolean belowControls) throws Exception {
        JSONObject trophy = live ? state.optJSONObject("trophy") : null;
        String signature = trophy == null ? "" : trophy.toString() + belowControls + insetTop;
        if (signature.equals(drawnTrophy)) return;
        drawnTrophy = signature;
        trophyLayer.removeAllViews();
        if (trophy == null) return;
        int tint = trophy.getInt("tint");
        LinearLayout toast = Look.row(this, 10);
        toast.setGravity(Gravity.CENTER_VERTICAL);
        toast.setPadding(Look.dp(8), Look.dp(8), Look.dp(14), Look.dp(8));
        toast.setBackground(Look.outlined(Look.black(0.62), 14, Look.white(0.08), 1));
        toast.setElevation(Look.dp(12));
        FrameLayout art = new FrameLayout(this);
        art.setBackground(Look.rounded(Look.white(0.06), 7));
        art.addView(new Look.Icon(this, "trophy", tint), Look.at(Look.dp(16), Look.dp(16), Gravity.CENTER));
        ImageView image = new ImageView(this);
        image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        Images.show(image, trophy.isNull("icon") ? null : trophy.getString("icon"), 128);
        art.addView(image, Look.whole());
        Look.round(art, 7);
        toast.addView(art, Look.sized(32, 32));
        int room = Look.dp(Math.max(120, Math.min(240, Math.round(root.getWidth() / Look.density) - 96)));
        LinearLayout words = Look.column(this, 1);
        TextView heading = Look.line(this, trophy.getString("heading"), 10, 600, tint), name = Look.line(this, trophy.getString("title"), 12, 600, Color.WHITE);
        heading.setMaxWidth(room); name.setMaxWidth(room);
        words.addView(heading);
        words.addView(name);
        toast.addView(words, Look.wrap());
        FrameLayout.LayoutParams place = Look.at(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        place.topMargin = insetTop + Look.dp(belowControls ? 56 : 12);
        trophyLayer.addView(toast, place);
        toast.setAlpha(0f);
        toast.setTranslationY(-Look.dp(12));
        toast.animate().alpha(1f).translationY(0).setDuration(250).start();
    }

    private void drawMenu() throws Exception {
        JSONObject menu = state.getJSONObject("menu");
        boolean shown = menu.getBoolean("open");
        menuLayer.setVisibility(shown ? View.VISIBLE : View.GONE);
        String signature = shown ? menu.toString() + Pad.connected() + root.getWidth() : "";
        if (signature.equals(drawnMenu)) return;
        drawnMenu = signature;
        menuLayer.removeAllViews();
        if (!shown) return;
        View dim = new View(this);
        dim.setBackgroundColor(Look.black(0.55));
        dim.setOnClickListener(view -> Shared.act("menuClose"));
        menuLayer.addView(dim, Look.whole());
        int width = Math.round(root.getWidth() / Look.density);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout centre = Look.column(this, 14);
        centre.setGravity(Gravity.CENTER);
        centre.setPadding(Look.dp(24), Look.dp(16), Look.dp(24), Look.dp(16));
        centre.setOnClickListener(view -> Shared.act("menuClose"));
        LinearLayout box = Look.column(this, 0);
        box.setBackground(Look.outlined(Look.black(0.62), 18, Look.white(0.08), 1));
        box.setClickable(true);
        box.setElevation(Look.dp(24));
        LinearLayout header = Look.row(this, 14);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(Look.dp(18), Look.dp(18), Look.dp(18), Look.dp(18));
        FrameLayout art = new FrameLayout(this);
        art.setBackground(Look.outlined(Look.white(0.06), 12, Look.white(0.08), 1));
        art.addView(new Look.Icon(this, "gamecontroller", Look.white(0.35)), Look.at(Look.dp(26), Look.dp(26), Gravity.CENTER));
        ImageView image = new ImageView(this);
        image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        Images.show(image, menu.isNull("art") ? null : menu.getString("art"), 320);
        art.addView(image, Look.whole());
        Look.round(art, 12);
        header.addView(art, Look.sized(72, 72));
        LinearLayout words = Look.column(this, 6);
        TextView title = Look.text(this, menu.getString("title"), 17, 600, Color.WHITE);
        title.setMaxLines(2);
        words.addView(title);
        LinearLayout facts = Look.row(this, 8);
        if (!menu.isNull("platform")) {
            TextView badge = Look.text(this, menu.getString("platform"), 10, 700, Look.CANVAS);
            badge.setPadding(Look.dp(6), Look.dp(2), Look.dp(6), Look.dp(2));
            badge.setBackground(Look.rounded(Color.WHITE, 4));
            facts.addView(badge);
        }
        facts.addView(Look.line(this, menu.getString("facts"), 12, 400, Look.white(0.65)));
        words.addView(facts);
        if (!menu.isNull("minutes")) words.addView(fact("clock", menu.getString("minutes")));
        if (menu.has("delay")) words.addView(fact("timer", menu.getString("delay")));
        header.addView(words, Look.weighted());
        box.addView(header, Look.fill());
        View line = new View(this);
        line.setBackgroundColor(Look.white(0.08));
        box.addView(line, Look.sized(-1, 1));
        if (!menu.isNull("notice")) {
            TextView notice = Look.line(this, menu.getString("notice"), 13, 500, Color.rgb(255, 199, 102));
            notice.setGravity(Gravity.CENTER_VERTICAL);
            notice.setPadding(Look.dp(18), 0, Look.dp(18), 0);
            box.addView(notice, Look.sized(-1, 44));
            View under = new View(this);
            under.setBackgroundColor(Look.white(0.08));
            box.addView(under, Look.sized(-1, 1));
        }
        LinearLayout rows = Look.column(this, 2);
        rows.setPadding(Look.dp(8), Look.dp(8), Look.dp(8), Look.dp(8));
        JSONArray items = menu.getJSONArray("items");
        int selection = menu.getInt("selection");
        for (int index = 0; index < items.length(); index++) rows.addView(row(items.getJSONObject(index), index == selection), Look.sized(-1, 44));
        box.addView(rows, Look.fill());
        centre.addView(box, Look.sized(Math.min(420, width - 48), -2));
        if (Pad.connected()) {
            LinearLayout hints = Look.row(this, 18);
            hints.addView(hint("✕", t("choose")));
            hints.addView(hint("○", t("goBack")));
            hints.addView(hint("PS", t("close")));
            centre.addView(hints);
        }
        scroll.addView(centre, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        menuLayer.addView(scroll, Look.whole());
    }

    private View fact(String icon, String words) {
        LinearLayout fact = Look.row(this, 4);
        fact.addView(new Look.Icon(this, icon, Look.white(0.65)), Look.sized(11, 11));
        fact.addView(Look.line(this, words, 12, 400, Look.white(0.65)));
        return fact;
    }

    private View row(JSONObject item, boolean chosen) throws Exception {
        String id = item.getString("id");
        boolean leaving = id.equals("leave");
        LinearLayout row = Look.row(this, 11);
        row.setPadding(Look.dp(10), 0, Look.dp(10), 0);
        row.setBackground(chosen ? Look.outlined(Look.white(0.1), 9, Look.white(0.9), 2) : Look.rounded(Color.TRANSPARENT, 9));
        String icon = id.equals("restart") ? "reload" : id.equals("resume") ? "play" : id.equals("stats") ? "chart" : leaving ? "xmark" : "menu";
        Look.Icon mark = new Look.Icon(this, icon, leaving ? Color.rgb(255, 107, 102) : Color.WHITE);
        mark.setPadding(Look.dp(6), Look.dp(6), Look.dp(6), Look.dp(6));
        mark.setBackground(Look.rounded(leaving ? Look.faded(Color.RED, 0.12) : Look.white(0.12), 6));
        row.addView(mark, Look.sized(24, 24));
        row.addView(Look.line(this, item.getString("title"), 13, 500, leaving ? Color.rgb(255, 128, 122) : Color.WHITE), Look.weighted());
        if (!item.isNull("state")) row.addView(Look.text(this, item.getString("state"), 12, 400, item.optBoolean("on") ? Look.ACCENT : Look.white(0.45)));
        row.setOnClickListener(view -> Shared.act("menuChoose", id));
        Look.pressable(row);
        return row;
    }

    private View hint(String key, String title) {
        LinearLayout hint = Look.row(this, 6);
        TextView mark = Look.text(this, key, 12, 500, Color.WHITE);
        mark.setPadding(Look.dp(6), Look.dp(1), Look.dp(6), Look.dp(1));
        mark.setBackground(Look.rounded(Look.white(0.12), 4));
        hint.addView(mark);
        hint.addView(Look.text(this, title, 12, 500, Look.white(0.6)));
        return hint;
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (!over && pad.key(event)) return true;
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean dispatchGenericMotionEvent(MotionEvent event) {
        if (!over && pad.motion(event)) return true;
        return super.dispatchGenericMotionEvent(event);
    }

    @Override public boolean dispatchTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN && cover.getVisibility() != View.VISIBLE && touchPad.getVisibility() != View.VISIBLE) reveal();
        return super.dispatchTouchEvent(event);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused) pad.release();
    }
    @Override public void onInputDeviceAdded(int device) { show(); }
    @Override public void onInputDeviceChanged(int device) {}
    @Override public void onInputDeviceRemoved(int device) { pad.release(); show(); }
}
