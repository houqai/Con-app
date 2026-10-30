package app.con.check;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.RenderEffect;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity {
    static final String TAG = "ConCheck";
    JSONObject state = new JSONObject(), texts = new JSONObject();
    int width = 400, height = 800;
    private int insetTop, insetBottom;
    private final Pad pad = new Pad();

    private FrameLayout root, content;
    private Backdrop backdrop;
    private LinearLayout library;
    private FrameLayout header, body, pageLayer, settingsLayer, loginLayer, choicesLayer, messageLayer, dialogLayer;
    private LinearLayout searchRow;
    private EditText search;
    private boolean searchExpanded;
    private FocusFrame frame;
    private final Map<String, String> drawn = new HashMap<>();
    private final Map<String, Map<String, View>> targets = new HashMap<>();
    private final Map<View, Float> corners = new HashMap<>();
    private final Map<View, Float> blurs = new WeakHashMap<>();
    private String sentTargets = "", logged = "", shownFocus;
    private int columns;
    private String wanted, registering;
    private boolean streamOpen;
    private ScrollView libraryScroll;
    private LinearLayout libraryColumn;
    private final Map<String, JSONArray> screenshots = new HashMap<>();
    private final Runnable watcher = this::show;
    private final Consumer<String> activator = this::activate;

    @Override protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Look.density = getResources().getDisplayMetrics().density;
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(Color.TRANSPARENT);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);

        root = new FrameLayout(this);
        root.setBackgroundColor(Look.CANVAS);
        backdrop = new Backdrop(this);
        root.addView(backdrop, Look.whole());
        content = new FrameLayout(this);
        content.setClipToPadding(false);
        content.setClipChildren(false);
        root.addView(content, Look.whole());
        library = Look.column(this, 0);
        content.addView(library, Look.whole());
        header = new FrameLayout(this);
        library.addView(header, Look.fill());
        searchRow = Look.row(this, 0);
        library.addView(searchRow, Look.fill());
        body = new FrameLayout(this);
        library.addView(body, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        pageLayer = layer(); settingsLayer = layer(); loginLayer = layer(); dialogLayer = layer(); choicesLayer = layer(); messageLayer = layer();
        frame = new FocusFrame(this);
        root.addView(frame, Look.whole());
        setContentView(root);
        search = searchField();

        root.setOnApplyWindowInsetsListener((view, insets) -> {
            insetTop = insets.getSystemWindowInsetTop();
            insetBottom = insets.getSystemWindowInsetBottom();
            content.setPadding(insets.getSystemWindowInsetLeft(), insetTop, insets.getSystemWindowInsetRight(), 0);
            redraw();
            return insets;
        });
        root.addOnLayoutChangeListener((view, left, top, right, bottom, a, b, c, d) -> {
            int newWidth = Math.round((right - left) / Look.density), newHeight = Math.round((bottom - top) / Look.density);
            if (newWidth != width || newHeight != height) { width = newWidth; height = newHeight; root.post(this::redraw); }
        });
        root.getViewTreeObserver().addOnGlobalLayoutListener(this::sendTargets);
        root.getViewTreeObserver().addOnScrollChangedListener(frame::invalidate);

        Shared.begin(this);
        Log.i(TAG, "start: " + Shared.certificates + " certificates, storage " + (Shared.storeCheck() ? "PASS" : "FAIL"));
        String device = Locale.getDefault().getLanguage();
        if (Arrays.asList("en", "ru", "de", "es", "fr", "it", "pl", "pt", "ja", "ko", "zh").contains(device)) Shared.act("deviceLanguage", device);
        long token = getIntent().getLongExtra("token", 0);
        SharedPreferences kept = getSharedPreferences("check", MODE_PRIVATE);
        boolean checking = new ComponentName(this, getPackageName() + ".CheckPlay").equals(getIntent().getComponent());
        if (saved == null && checking && token != 0 && token != kept.getLong("played", 0)) {
            wanted = getIntent().getStringExtra("play");
            kept.edit().putLong("played", token).apply();
        }
    }

    @Override protected void onStart() {
        super.onStart();
        Shared.onChange = watcher;
        Shared.onActivate = activator;
        show();
    }

    @Override protected void onStop() {
        super.onStop();
        if (Shared.onChange == watcher) Shared.onChange = null;
        if (Shared.onActivate == activator) Shared.onActivate = null;
    }

    private FrameLayout layer() {
        FrameLayout layer = new FrameLayout(this);
        layer.setClipChildren(false);
        layer.setVisibility(View.GONE);
        content.addView(layer, Look.whole());
        return layer;
    }

    String t(String key) { return texts.optString(key, key); }

    private void redraw() { drawn.clear(); show(); }

    private boolean changed(String part, Object... what) {
        StringBuilder text = new StringBuilder().append(width).append('x').append(height).append(':').append(insetBottom);
        for (Object one : what) text.append('|').append(one);
        String now = text.toString();
        if (now.equals(drawn.get(part))) return false;
        drawn.put(part, now);
        return true;
    }

    void show() {
        try {
            state = Shared.now();
            if (!state.has("signingIn")) return;
            texts = state.getJSONObject("t");
            boolean cloud = state.getString("destination").equals("cloud");
            int[] glow = { state.getJSONArray("glow").getInt(0), state.getJSONArray("glow").getInt(1) };
            backdrop.set(glow[0], glow[1]);
            drawHeader(cloud);
            if (cloud) drawLibrary(); else drawConsoles();
            drawPage();
            drawSettings();
            drawLogin();
            drawChoices();
            drawMessage();
            drawDialogs();
            boolean covered = settingsLayer.getVisibility() == View.VISIBLE || pageLayer.getVisibility() == View.VISIBLE;
            library.setVisibility(pageLayer.getVisibility() == View.VISIBLE ? View.INVISIBLE : View.VISIBLE);
            blur(library, covered ? 18 : 0);
            blur(pageLayer, settingsLayer.getVisibility() == View.VISIBLE ? 18 : 0);
            openStream();
            playWanted();
            focusFrame();
            report();
        } catch (Exception error) {
            Log.e(TAG, "FAIL " + error, error);
        }
    }

    private void blur(View view, float radius) {
        if (Build.VERSION.SDK_INT < 31) return;
        Float was = blurs.get(view);
        if (was != null && was == radius) return;
        blurs.put(view, radius);
        view.setRenderEffect(radius > 0 ? RenderEffect.createBlurEffect(Look.dp(radius), Look.dp(radius), Shader.TileMode.CLAMP) : null);
    }

    private void openStream() throws Exception {
        String phase = state.getString("phase");
        boolean live = phase.equals("connecting") || phase.equals("streaming");
        boolean wants = state.getBoolean("launching") || live;
        if (wants && !streamOpen) {
            streamOpen = true;
            startActivity(new Intent(this, StreamActivity.class));
        } else if (!wants) {
            streamOpen = false;
        }
    }

    private boolean signedIn() { return !state.isNull("account"); }

    private boolean busy() throws Exception { return state.getBoolean("signingIn") || state.getBoolean("restoring") || state.getBoolean("signingOut"); }

    private void playWanted() throws Exception {
        if (wanted == null || !signedIn() || busy() || state.getInt("catalogue") == 0 || state.getInt("history") == 0) return;
        String part = wanted.toLowerCase(Locale.ROOT);
        wanted = null;
        JSONArray listed = state.getJSONArray("listed"), ids = state.getJSONArray("listedIDs");
        int found = -1;
        for (int index = 0; index < listed.length() && found < 0; index++) if (listed.getString(index).toLowerCase(Locale.ROOT).contains(part)) found = index;
        Log.i(TAG, found < 0 ? "play: no listed game has \"" + part + "\" in its title" : "play: " + listed.getString(found));
        if (found >= 0) Shared.act("play", ids.getString(found));
    }

    private void report() throws Exception {
        String line = "state: account " + signedIn() + " busy " + busy() + " signingIn " + state.getBoolean("signingIn") + " error " + !state.isNull("authError")
                + " catalogue " + state.getInt("catalogue") + " history " + state.getInt("history") + " owned " + state.getBoolean("owned") + " listed " + state.getInt("listedCount");
        if (!line.equals(logged)) { logged = line; Log.i(TAG, line); }
    }

    private void drawHeader(boolean cloud) throws Exception {
        String account = state.isNull("account") ? null : state.getString("account");
        if (!changed("header", cloud, account, state.opt("avatar"), searchExpanded, texts.optString("search"))) return;
        clear("header");
        header.removeAllViews();
        LinearLayout bar = Look.row(this, 0);
        bar.setPadding(Look.dp(width < 600 ? 20 : 24), 0, Look.dp(width < 600 ? 16 : 24), 0);
        header.addView(bar, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, Look.dp(width < 600 ? 64 : 76)));
        LinearLayout brand = Look.row(this, 10);
        brand.addView(Look.logo(this, 38), Look.sized(38, 38));
        brand.addView(Look.text(this, "Con", 20, 600, Look.TEXT));
        bar.addView(brand, Look.margins(Look.wrap(), 0, 0, width < 1120 ? 16 : 36, 0));
        if (width >= 1120 && state.optBoolean("consolesShown")) {
            LinearLayout tabs = Look.row(this, 28);
            tabs.addView(navigation(t("cloudGames"), cloud, "cloud"));
            tabs.addView(navigation(t("consoles"), !cloud, "consoles"));
            bar.addView(tabs);
        }
        bar.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
        if (cloud) {
            if (width >= 850) {
                detach(search);
                bar.addView(searchBox(), Look.margins(Look.sized(width < 1250 ? 200 : 268, 36), 0, 0, 14, 0));
            } else {
                Look.Icon find = Look.iconButton(this, "search", t("search"));
                find.setOnClickListener(view -> { searchExpanded = !searchExpanded; show(); if (searchExpanded) focusSearch(); });
                bar.addView(find, Look.margins(Look.sized(36, 36), 0, 0, 12, 0));
                target("header", find, "search", 18);
            }
            if (width >= 1120) {
                Look.Icon reload = Look.iconButton(this, "reload", t("reload"));
                reload.setOnClickListener(view -> Shared.act("reload"));
                bar.addView(reload, Look.margins(Look.sized(36, 36), 0, 0, 14, 0));
                target("header", reload, "icon:" + t("reload"), 18);
            }
        }
        if (width < 1120) {
            Look.Icon menu = Look.iconButton(this, "menu", t("settings"));
            menu.setPadding(Look.dp(9), Look.dp(9), Look.dp(9), Look.dp(9));
            menu.setOnClickListener(view -> Shared.act("headerMenu"));
            bar.addView(menu, Look.margins(Look.sized(36, 36), 0, 0, 12, 0));
            target("header", menu, "header-menu", 18);
        } else {
            Look.Icon gear = Look.iconButton(this, "gear", t("settings"));
            gear.setOnClickListener(view -> Shared.act("settings", ""));
            bar.addView(gear, Look.margins(Look.sized(36, 36), 0, 0, 22, 0));
            target("header", gear, "icon:" + t("settings"), 18);
        }
        LinearLayout person = Look.row(this, 10);
        person.addView(avatar(36, account != null), Look.sized(36, 36));
        if (width >= 1300) {
            LinearLayout words = Look.column(this, 3);
            words.addView(Look.text(this, account != null ? account : "PlayStation", 13, 600, Look.TEXT));
            words.addView(Look.text(this, account == null ? t("signInShort") : t("connected"), 11, 400, Look.white(0.55)));
            person.addView(words);
        }
        Look.pressable(person);
        person.setOnClickListener(view -> Shared.act("settings", "PSN Account"));
        bar.addView(person);
        target("header", person, "account", 22);
        searchRow.removeAllViews();
        if (cloud && width < 850 && searchExpanded) {
            detach(search);
            searchRow.setPadding(Look.dp(24), 0, Look.dp(24), Look.dp(12));
            searchRow.addView(searchBox(), new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Look.dp(36)));
        } else searchRow.setPadding(0, 0, 0, 0);
    }

    private TextView navigation(String title, boolean selected, String destination) {
        TextView tab = Look.text(this, title, 16, 500, Look.TEXT);
        tab.setAlpha(selected ? 1 : 0.55f);
        tab.setPadding(Look.dp(6), Look.dp(10), Look.dp(6), Look.dp(10));
        tab.setOnClickListener(view -> Shared.act("destination", destination));
        target("header", tab, "nav:" + title, 8);
        return tab;
    }

    View avatar(double size, boolean signedIn) {
        FrameLayout avatar = new FrameLayout(this);
        ImageView picture = new ImageView(this);
        picture.setScaleType(ImageView.ScaleType.CENTER_CROP);
        picture.setBackground(Look.capsule(Color.rgb(42, 47, 69)));
        Look.round(picture, size / 2);
        Images.show(picture, state.isNull("avatar") ? null : state.optString("avatar"), 192);
        avatar.addView(picture, Look.whole());
        View ring = new View(this);
        GradientDrawable outline = Look.capsule(Color.TRANSPARENT);
        outline.setStroke(Look.dp(2), Look.white(0.18));
        ring.setBackground(outline);
        avatar.addView(ring, Look.whole());
        View dot = new View(this);
        GradientDrawable light = Look.capsule(signedIn ? Color.rgb(52, 199, 89) : Color.GRAY);
        light.setStroke(Look.dp(2), Look.CANVAS);
        dot.setBackground(light);
        avatar.addView(dot, Look.at(Look.dp(10), Look.dp(10), Gravity.BOTTOM | Gravity.END));
        return avatar;
    }

    private EditText searchField() {
        EditText field = new EditText(this);
        field.setSingleLine(true);
        field.setBackground(null);
        field.setTextColor(Look.TEXT);
        field.setHintTextColor(Look.white(0.45));
        field.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 14);
        field.setPadding(0, 0, 0, 0);
        field.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable text) { if (!text.toString().equals(state.optString("search"))) Shared.act("search", text.toString()); }
        });
        field.setOnEditorActionListener((view, action, event) -> { hideKeyboard(view); return true; });
        return field;
    }

    private View searchBox() {
        LinearLayout box = Look.row(this, 9);
        box.setPadding(Look.dp(14), 0, Look.dp(14), 0);
        box.setBackground(Look.outlined(Look.white(0.08), 999, Look.white(0.08), 1));
        Look.Icon glass = new Look.Icon(this, "search", Look.white(0.6));
        box.addView(glass, Look.sized(16, 16));
        search.setHint(t("search"));
        if (!search.hasFocus() && !search.getText().toString().equals(state.optString("search"))) search.setText(state.optString("search"));
        box.addView(search, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        search.setGravity(Gravity.CENTER_VERTICAL);
        box.setOnClickListener(view -> focusSearch());
        target("header", box, "search", 18);
        return box;
    }

    private void focusSearch() {
        search.post(() -> {
            search.requestFocus();
            ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(search, InputMethodManager.SHOW_IMPLICIT);
        });
    }

    void hideKeyboard(View view) {
        ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(view.getWindowToken(), 0);
        view.clearFocus();
    }

    private static void detach(View view) {
        if (view.getParent() instanceof ViewGroup) ((ViewGroup) view.getParent()).removeView(view);
    }

    private void drawLibrary() throws Exception {
        int count = Math.max(2, Math.min(6, (width - 48 + 22) / 202));
        if (count != columns) { columns = count; Shared.act("columns", String.valueOf(count)); }
        if (libraryScroll == null || libraryScroll.getParent() == null) {
            body.removeAllViews();
            drawn.remove("heading"); drawn.remove("tiles");
            libraryScroll = new ScrollView(this);
            libraryScroll.setVerticalScrollBarEnabled(false);
            libraryScroll.setClipToPadding(false);
            libraryColumn = Look.column(this, 0);
            libraryScroll.addView(libraryColumn, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT));
            body.addView(libraryScroll, Look.whole());
        }
        String backend = state.getString("backend"), filter = state.getString("filter");
        if (changed("heading", backend, filter, state.get("filters"), state.getString("countText"))) {
            clear("heading");
            View old = libraryColumn.findViewWithTag("heading");
            if (old != null) libraryColumn.removeView(old);
            LinearLayout heading = width < 1050 ? Look.column(this, 14) : Look.row(this, 0);
            heading.setTag("heading");
            heading.setPadding(Look.dp(24), Look.dp(12), Look.dp(24), Look.dp(4));
            LinearLayout titles = Look.row(this, width < 760 ? 10 : 20);
            LinearLayout title = Look.row(this, 12);
            title.addView(Look.line(this, t("catalogue"), width < 760 ? 14 : 18, 600, Look.TEXT));
            if (width >= 760) { TextView number = Look.line(this, state.getString("countText"), 14, 400, Look.TEXT); number.setAlpha(0.5f); title.addView(number); }
            titles.addView(title);
            LinearLayout sources = Look.row(this, 8);
            String[][] backends = { { "ps5", "PS5" }, { "psPlusPC", "PS4" }, { "ps3", "PS3" } };
            for (String[] one : backends) {
                boolean chosen = one[0].equals(backend);
                TextView pill = Look.line(this, one[1], width < 760 ? 12 : 14, 600, chosen ? Look.CANVAS : Look.white(0.7));
                pill.setPadding(Look.dp(width < 760 ? 10 : 16), Look.dp(7), Look.dp(width < 760 ? 10 : 16), Look.dp(7));
                pill.setBackground(Look.capsule(chosen ? Color.WHITE : Look.white(0.07)));
                pill.setOnClickListener(view -> Shared.act("backend", one[0]));
                Look.pressable(pill);
                sources.addView(pill);
                target("heading", pill, "catalog-source:" + one[0], 16);
            }
            titles.addView(sources);
            heading.addView(titles);
            if (width >= 1050) heading.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
            HorizontalScrollView sliding = new HorizontalScrollView(this);
            sliding.setHorizontalScrollBarEnabled(false);
            sliding.setClipToPadding(false);
            LinearLayout filters = Look.row(this, 0);
            filters.setPadding(Look.dp(4), Look.dp(4), Look.dp(4), Look.dp(4));
            filters.setBackground(Look.capsule(Look.white(0.07)));
            JSONArray available = state.getJSONArray("filters");
            for (int index = 0; index < available.length(); index++) {
                String id = available.getJSONArray(index).getString(0), name = available.getJSONArray(index).getString(1);
                boolean chosen = id.equals(filter);
                TextView pill = Look.line(this, name, 13, 400, chosen ? Look.CANVAS : Look.white(0.75));
                pill.setGravity(Gravity.CENTER);
                pill.setPadding(Look.dp(16), 0, Look.dp(16), 0);
                pill.setBackground(chosen ? Look.capsule(Color.WHITE) : null);
                pill.setOnClickListener(view -> Shared.act("filter", id));
                filters.addView(pill, Look.sized(-2, 30));
                target("heading", pill, "filter:" + id, 15);
            }
            sliding.addView(filters);
            heading.addView(sliding, Look.wrap());
            libraryColumn.addView(heading, 0);
        }
        JSONArray tiles = state.getJSONArray("tiles");
        if (changed("tiles", tiles, state.optBoolean("more"), state.opt("empty"), state.opt("error"), columns)) {
            clear("tiles");
            View old = libraryColumn.findViewWithTag("tiles");
            if (old != null) libraryColumn.removeView(old);
            LinearLayout list = Look.column(this, 24);
            list.setTag("tiles");
            list.setPadding(Look.dp(24), Look.dp(20), Look.dp(24), Look.dp(40) + insetBottom);
            int tile = Look.dp((width - 48 - (columns - 1) * 22) / (double) columns);
            LinearLayout grid = Look.column(this, 22);
            LinearLayout line = null;
            for (int index = 0; index < tiles.length(); index++) {
                if (index % columns == 0) { line = Look.row(this, 22); grid.addView(line); }
                line.addView(card(tiles.getJSONObject(index)), new LinearLayout.LayoutParams(tile, tile));
            }
            list.addView(grid);
            if (!state.isNull("empty")) {
                TextView empty = Look.text(this, state.getString("empty"), 15, 400, Look.white(0.6));
                empty.setGravity(Gravity.CENTER);
                empty.setPadding(Look.dp(40), Look.dp(40), Look.dp(40), Look.dp(40));
                list.addView(empty, Look.fill());
            }
            if (state.optBoolean("more")) {
                TextView more = Look.quiet(this, t("more"), false);
                more.setOnClickListener(view -> Shared.act("more"));
                LinearLayout centred = Look.row(this, 0);
                centred.setGravity(Gravity.CENTER);
                centred.addView(more);
                list.addView(centred, Look.fill());
                target("tiles", more, "more-games", 21);
            }
            if (!state.isNull("error")) list.addView(Look.text(this, state.getString("error"), 13, 400, Look.white(0.6)));
            libraryColumn.addView(list);
        }
    }

    private View card(JSONObject game) throws Exception {
        String id = game.getString("id");
        FrameLayout card = new FrameLayout(this);
        card.addView(cover(game, 12, 32), Look.whole());
        TextView title = Look.text(this, game.getString("title"), 15, 600, Color.WHITE);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setPadding(Look.dp(12), Look.dp(28), Look.dp(12), Look.dp(12));
        GradientDrawable shade = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[] { Color.TRANSPARENT, Look.black(0.85) });
        float corner = Look.dp(12);
        shade.setCornerRadii(new float[] { 0, 0, 0, 0, corner, corner, corner, corner });
        title.setBackground(shade);
        card.addView(title, Look.at(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));
        boolean favourite = game.getBoolean("fav");
        Look.Icon star = new Look.Icon(this, favourite ? "star.fill" : "star", Color.WHITE);
        star.setPadding(Look.dp(7), Look.dp(7), Look.dp(7), Look.dp(7));
        star.setBackground(Look.capsule(Look.black(0.35)));
        star.setOnClickListener(view -> Shared.act("favorite", id));
        Look.pressable(star);
        card.addView(star, Look.margins(Look.at(Look.dp(28), Look.dp(28), Gravity.TOP | Gravity.END), 0, 8, 8, 0));
        card.setOnClickListener(view -> { hideKeyboard(search); Shared.act("open", id); });
        card.setContentDescription(game.getString("title"));
        target("tiles", card, "game:" + id, 18);
        return card;
    }

    View cover(JSONObject game, double radius, double iconSize) throws Exception {
        FrameLayout cover = new FrameLayout(this);
        cover.setBackground(Look.rounded(game.getInt("tint"), radius));
        Look.Icon mark = new Look.Icon(this, "gamecontroller", Look.white(0.6));
        cover.addView(mark, Look.at(Look.dp(iconSize * 1.3), Look.dp(iconSize * 1.3), Gravity.CENTER));
        ImageView picture = new ImageView(this);
        picture.setScaleType(ImageView.ScaleType.CENTER_CROP);
        cover.addView(picture, Look.whole());
        Images.show(picture, game.isNull("art") ? null : game.getString("art"), 640);
        Look.round(cover, radius);
        return cover;
    }

    private void drawPage() throws Exception {
        JSONObject game = state.optJSONObject("page");
        boolean open = state.getBoolean("gameOpen") && game != null;
        pageLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!open) { if (changed("page", "closed")) { clear("page"); pageLayer.removeAllViews(); } return; }
        if (!changed("page", game)) return;
        clear("page");
        pageLayer.removeAllViews();
        String id = game.getString("id");
        FrameLayout back = new FrameLayout(this);
        back.setBackgroundColor(game.getInt("backdrop"));
        ImageView spread = new ImageView(this);
        spread.setScaleType(ImageView.ScaleType.CENTER_CROP);
        Images.show(spread, game.isNull("art") ? null : game.getString("art"), Build.VERSION.SDK_INT >= 31 ? 640 : 24);
        if (Build.VERSION.SDK_INT >= 31) spread.setRenderEffect(RenderEffect.createBlurEffect(Look.dp(50), Look.dp(50), Shader.TileMode.CLAMP));
        back.addView(spread, Look.whole());
        View dim = new View(this);
        dim.setBackgroundColor(Look.faded(Look.CANVAS, 0.45));
        back.addView(dim, Look.whole());
        View fall = new View(this);
        fall.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[] { Look.faded(Look.CANVAS, 0.2), Look.faded(Look.CANVAS, 0.9) }));
        back.addView(fall, Look.whole());
        pageLayer.addView(back, underBars());

        boolean narrow = width < 900, phone = width < 600, compact = width < 1100;
        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout column = Look.column(this, 24);
        column.setPadding(Look.dp(narrow ? 24 : 64), Look.dp(phone ? 76 : 96), Look.dp(narrow ? 24 : 64), Look.dp(60) + insetBottom);
        LinearLayout details = Look.column(this, 0);
        TextView kicker = Look.text(this, game.getString("kicker"), 13, 600, Look.TEXT);
        kicker.setLetterSpacing(0.06f);
        kicker.setAlpha(0.7f);
        details.addView(kicker);
        TextView title = Look.text(this, game.getString("title"), narrow ? 28 : 44, 700, Look.TEXT);
        title.setLetterSpacing(-0.02f);
        title.setMaxLines(3);
        details.addView(title, Look.margins(Look.wrap(), 0, 12, 0, 0));
        LinearLayout buttons = Look.row(this, 12);
        LinearLayout play = Look.row(this, 10);
        play.setGravity(Gravity.CENTER);
        play.setPadding(Look.dp(34), 0, Look.dp(34), 0);
        play.setBackground(Look.capsule(Color.WHITE));
        play.addView(new Look.Icon(this, "play", Look.CANVAS), Look.sized(14, 14));
        play.addView(Look.text(this, t("play"), 16, 600, Look.CANVAS));
        Look.pressable(play);
        play.setOnClickListener(view -> Shared.act("play", id));
        buttons.addView(play, Look.sized(-2, 48));
        target("page", play, "page-play", 24);
        boolean favourite = game.getBoolean("fav");
        View favour = pill(favourite ? "star.fill" : "star", compact ? null : t(favourite ? "favorited" : "favorite"));
        favour.setOnClickListener(view -> Shared.act("favorite", id));
        buttons.addView(favour, Look.sized(-2, 48));
        target("page", favour, "page-favorite", 24);
        if (!game.isNull("store")) {
            View store = pill("arrow.up.right", compact ? null : t("store"));
            String address = game.getString("store");
            store.setOnClickListener(view -> { try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(address))); } catch (Exception none) { Log.e(TAG, "no browser"); } });
            buttons.addView(store, Look.sized(-2, 48));
            target("page", store, "page-store", 24);
        }
        details.addView(buttons, Look.margins(Look.wrap(), 0, 26, 0, 0));
        int thumbnails = Math.max(100, Math.min(220, (int) (height * 0.26)));
        int hero = Math.max(120, height - 96 - 60 - 24 - thumbnails - 54);
        if (phone) {
            int size = Math.min(240, width - 48);
            View art = cover(game, 12, 40);
            art.setElevation(Look.dp(12));
            column.addView(art, Look.sized(size, size));
            column.addView(details, Look.fill());
        } else {
            int size = (int) Math.min(Math.min(narrow ? 160 : 320, hero), width * 0.24);
            LinearLayout top = Look.row(this, narrow ? 24 : 44);
            View art = cover(game, 12, 40);
            art.setElevation(Look.dp(12));
            top.addView(art, Look.sized(size, size));
            top.addView(details, Look.weighted());
            column.addView(top, Look.fill());
        }
        LinearLayout gallery = Look.column(this, 16);
        gallery.setTag("gallery");
        column.addView(gallery, Look.fill());
        scroll.addView(column);
        pageLayer.addView(scroll, Look.whole());
        LinearLayout backButton = Look.row(this, 6);
        backButton.setPadding(Look.dp(12), 0, Look.dp(16), 0);
        backButton.setBackground(Look.capsule(Look.white(0.1)));
        backButton.addView(new Look.Icon(this, "chevron.left", Color.WHITE), Look.sized(16, 16));
        backButton.addView(Look.text(this, t("back"), 14, 500, Color.WHITE));
        Look.pressable(backButton);
        backButton.setOnClickListener(view -> Shared.act("closePage"));
        pageLayer.addView(backButton, Look.margins(Look.at(FrameLayout.LayoutParams.WRAP_CONTENT, Look.dp(36), Gravity.TOP | Gravity.START), 24, phone ? 14 : 20, 0, 0));
        target("page", backButton, "page-back", 18);
        fillGallery(gallery, id, thumbnails);
    }

    private View pill(String icon, String words) {
        LinearLayout pill = Look.row(this, 8);
        pill.setGravity(Gravity.CENTER);
        pill.setPadding(Look.dp(20), 0, Look.dp(20), 0);
        pill.setBackground(Look.capsule(Look.white(0.12)));
        pill.addView(new Look.Icon(this, icon, Color.WHITE), Look.sized(16, 16));
        if (words != null) pill.addView(Look.text(this, words, 15, 500, Color.WHITE));
        Look.pressable(pill);
        return pill;
    }

    private void fillGallery(LinearLayout gallery, String id, int thumbnailHeight) {
        JSONArray known = screenshots.get(id);
        if (known == null) {
            new Thread(() -> {
                JSONArray urls;
                try { urls = new JSONObject(Shared.ask("screenshots", id)).optJSONArray("urls"); } catch (Exception broken) { urls = null; }
                JSONArray found = urls == null ? new JSONArray() : urls;
                runOnUiThread(() -> {
                    screenshots.put(id, found);
                    if (gallery.isAttachedToWindow()) fillGallery(gallery, id, thumbnailHeight);
                });
            }).start();
            return;
        }
        gallery.removeAllViews();
        if (known.length() == 0) return;
        gallery.addView(Look.text(this, t("screenshots"), 18, 600, Look.TEXT));
        int available = width - (width < 900 ? 48 : 128);
        int count = Math.min(known.length(), available > 1000 ? 6 : available > 700 ? 4 : 3);
        int rows = (known.length() + count - 1) / count;
        double side = Math.min((available - (count - 1) * 16) / (double) count, Math.max(40, (thumbnailHeight - (rows - 1) * 16) / (double) rows) * 16 / 9);
        LinearLayout lines = Look.column(this, 16);
        LinearLayout line = null;
        for (int index = 0; index < known.length(); index++) {
            if (index % count == 0) { line = Look.row(this, 16); lines.addView(line); }
            ImageView shot = new ImageView(this);
            shot.setScaleType(ImageView.ScaleType.CENTER_CROP);
            shot.setBackground(Look.rounded(Look.white(0.05), 10));
            Look.round(shot, 10);
            Images.show(shot, known.optString(index), 640);
            shot.setFocusable(false);
            line.addView(shot, Look.sized(side, side * 9 / 16));
            target("page", shot, "screenshot:" + index, 14);
        }
        gallery.addView(lines);
        sendTargets();
    }

    private void drawConsoles() throws Exception {
        if (libraryScroll != null && libraryScroll.getParent() != null) { body.removeAllViews(); clear("heading"); clear("tiles"); }
        JSONObject consoles = state.getJSONObject("consoles");
        if (!changed("consoles", consoles, state.isNull("account"))) return;
        clear("consoles");
        body.removeAllViews();
        body.addView(ConsolesPage.build(this, consoles), Look.whole());
    }

    private void drawSettings() throws Exception {
        JSONObject settings = state.getJSONObject("settings");
        boolean open = settings.getBoolean("open");
        settingsLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!open) { if (changed("settings", "closed")) { clear("settings"); settingsLayer.removeAllViews(); } return; }
        if (!changed("settings", settings, state.opt("account"), state.opt("avatar"), state.opt("authError"), state.opt("held"), state.optBoolean("restoring"), state.optBoolean("signingOut"), Pad.names())) return;
        clear("settings");
        settingsLayer.removeAllViews();
        settingsLayer.addView(dimmer(() -> Shared.act("closeSettings")), underBars());
        int panelWidth = Math.min(1000, width - (width < 600 ? 24 : 40)), panelHeight = Math.min(640, height - Math.round(insetTop / Look.density) - Math.round(insetBottom / Look.density) - 24);
        View panel = SettingsPanel.build(this, settings, panelWidth, panelHeight);
        settingsLayer.addView(panel, Look.at(Look.dp(panelWidth), Look.dp(panelHeight), Gravity.CENTER));
    }

    private void drawLogin() throws Exception {
        boolean open = state.getBoolean("loginOpen");
        loginLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!open) { if (changed("login", "closed")) { clear("login"); loginLayer.removeAllViews(); } return; }
        boolean signingIn = state.getBoolean("signingIn");
        if (!changed("login", signingIn, state.opt("authError"), state.optBoolean("restoring"), state.optBoolean("signingOut"))) return;
        clear("login");
        loginLayer.removeAllViews();
        loginLayer.addView(dimmer(() -> Shared.act("loginOpen", "0")), underBars());
        LinearLayout sheet = Look.column(this, 0);
        sheet.setGravity(Gravity.CENTER_HORIZONTAL);
        sheet.setBackground(Look.outlined(Look.CANVAS, 22, Look.white(0.08), 1));
        sheet.setPadding(Look.dp(23), Look.dp(18), Look.dp(23), Look.dp(24));
        FrameLayout top = new FrameLayout(this);
        LinearLayout brand = Look.row(this, 7);
        brand.addView(Look.logo(this, 25), Look.sized(25, 25));
        brand.addView(Look.text(this, "Con", 14, 500, Look.TEXT));
        top.addView(brand, Look.at(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.START | Gravity.CENTER_VERTICAL));
        Look.Icon close = Look.iconButton(this, "xmark", t("close"));
        close.setOnClickListener(view -> Shared.act("loginOpen", "0"));
        top.addView(close, Look.at(Look.dp(36), Look.dp(36), Gravity.END | Gravity.CENTER_VERTICAL));
        target("login", close, "icon:" + t("close"), 18);
        sheet.addView(top, Look.fill());
        Look.Icon person = new Look.Icon(this, "person", Look.ACCENT);
        sheet.addView(person, Look.margins(Look.sized(46, 46), 0, 26, 0, 0));
        TextView title = Look.text(this, t("connectPS"), 24, 600, Look.TEXT);
        title.setGravity(Gravity.CENTER);
        sheet.addView(title, Look.margins(Look.wrap(), 0, 20, 0, 0));
        TextView one = Look.text(this, t("oneSignIn"), 12, 400, Look.white(0.55));
        one.setGravity(Gravity.CENTER);
        sheet.addView(one, Look.margins(Look.wrap(), 0, 9, 0, 0));
        TextView how = Look.text(this, t("signInSony"), 12, 400, Look.white(0.55));
        how.setGravity(Gravity.CENTER);
        how.setLineSpacing(Look.dp(5), 1);
        sheet.addView(how, Look.margins(Look.wrap(), 0, 25, 0, 0));
        LinearLayout go = Look.row(this, 9);
        go.setGravity(Gravity.CENTER);
        go.setBackground(Look.capsule(Color.WHITE));
        go.addView(Look.text(this, signingIn ? t("waiting") : t("signInButton"), 15, 600, Look.CANVAS));
        go.addView(new Look.Icon(this, "arrow.up.right", Look.CANVAS), Look.sized(11, 11));
        Look.pressable(go);
        go.setOnClickListener(view -> Shared.act("signIn"));
        Look.enable(go, !signingIn && !state.getBoolean("restoring") && !state.getBoolean("signingOut"));
        sheet.addView(go, Look.margins(Look.sized(266, 42), 0, 22, 0, 0));
        target("login", go, "login-go", 21);
        if (signingIn) {
            TextView cancel = Look.text(this, t("cancelSignIn"), 11, 400, Look.white(0.55));
            cancel.setPadding(Look.dp(8), Look.dp(8), Look.dp(8), Look.dp(4));
            cancel.setOnClickListener(view -> Shared.act("cancelSignIn"));
            sheet.addView(cancel, Look.margins(Look.wrap(), 0, 4, 0, 0));
            target("login", cancel, "login-cancel", 8);
        }
        boolean failed = !state.isNull("authError");
        TextView note = Look.text(this, failed ? state.getString("authError") : t("passwordNote"), 10, 400, failed ? Look.ACCENT : Look.white(0.55));
        note.setGravity(Gravity.CENTER);
        note.setPadding(Look.dp(30), 0, Look.dp(30), 0);
        sheet.addView(note, Look.margins(Look.wrap(), 0, 15, 0, 0));
        loginLayer.addView(sheet, Look.at(Look.dp(Math.min(460, width - 32)), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
    }

    View dimmer(Runnable onTap) {
        View dim = new View(this);
        dim.setBackgroundColor(Color.argb(140, 3, 5, 12));
        dim.setOnClickListener(view -> onTap.run());
        return dim;
    }
    FrameLayout.LayoutParams underBars() {
        FrameLayout.LayoutParams under = Look.whole();
        under.topMargin = -insetTop;
        return under;
    }

    private void drawChoices() throws Exception {
        JSONArray choices = state.getJSONArray("choices");
        int chosen = state.getInt("choiceIndex");
        boolean open = choices.length() > 0;
        choicesLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!changed("choices", choices, chosen)) return;
        choicesLayer.removeAllViews();
        if (!open) return;
        View dim = new View(this);
        dim.setBackgroundColor(Look.black(0.55));
        dim.setOnClickListener(view -> Shared.act("choice", "-1"));
        choicesLayer.addView(dim, underBars());
        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setBackground(Look.rounded(Look.PANEL, 18));
        LinearLayout list = Look.column(this, 6);
        list.setPadding(Look.dp(16), Look.dp(16), Look.dp(16), Look.dp(16));
        View shown = null;
        for (int index = 0; index < choices.length(); index++) {
            TextView row = Look.text(this, choices.getString(index), 16, 400, Look.TEXT);
            row.setPadding(Look.dp(14), Look.dp(14), Look.dp(14), Look.dp(14));
            boolean here = index == chosen;
            row.setBackground(here ? Look.outlined(Look.faded(Look.ACCENT, 0.3), 10, Color.WHITE, 2) : Look.rounded(Color.TRANSPARENT, 10));
            final int which = index;
            row.setOnClickListener(view -> Shared.act("choice", String.valueOf(which)));
            list.addView(row, Look.fill());
            if (here) shown = row;
        }
        scroll.addView(list);
        int tall = Math.min(Math.min(360, height - 120), choices.length() * 53 + 32);
        choicesLayer.addView(scroll, Look.at(Look.dp(Math.min(360, width - 32)), Look.dp(tall), Gravity.CENTER));
        View visible = shown;
        if (visible != null) scroll.post(() -> scroll.scrollTo(0, Math.max(0, visible.getTop() - scroll.getHeight() / 2 + visible.getHeight() / 2)));
    }

    private void drawMessage() throws Exception {
        boolean open = !state.isNull("message");
        messageLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!changed("message", state.opt("message"))) return;
        messageLayer.removeAllViews();
        if (!open) return;
        messageLayer.addView(dimmer(() -> Shared.act("message")), underBars());
        LinearLayout box = Look.column(this, 14);
        box.setBackground(Look.outlined(Look.PANEL, 18, Look.white(0.08), 1));
        box.setPadding(Look.dp(22), Look.dp(22), Look.dp(22), Look.dp(18));
        box.addView(Look.text(this, "Con", 17, 600, Look.TEXT));
        box.addView(Look.text(this, state.getString("message"), 14, 400, Look.white(0.75)));
        TextView ok = Look.quiet(this, t("understood"), true);
        ok.setOnClickListener(view -> Shared.act("message"));
        LinearLayout end = Look.row(this, 0);
        end.setGravity(Gravity.END);
        end.addView(ok);
        box.addView(end, Look.fill());
        messageLayer.addView(box, Look.at(Look.dp(Math.min(400, width - 40)), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
    }

    void register(String id, String name) { registering = id + "\n" + name; drawn.remove("dialogs"); show(); }

    private void drawDialogs() throws Exception {
        JSONObject consoles = state.getJSONObject("consoles");
        boolean pin = consoles.getBoolean("pinRequest");
        boolean open = registering != null || pin;
        dialogLayer.setVisibility(open ? View.VISIBLE : View.GONE);
        if (!changed("dialogs", registering, pin)) return;
        dialogLayer.removeAllViews();
        if (!open) return;
        String[] console = registering == null ? null : registering.split("\n", 2);
        dialogLayer.addView(dimmer(() -> { if (console != null) { registering = null; drawn.remove("dialogs"); show(); } }), underBars());
        LinearLayout box = Look.column(this, 16);
        box.setBackground(Look.outlined(Look.PANEL, 18, Look.white(0.08), 1));
        box.setPadding(Look.dp(22), Look.dp(22), Look.dp(22), Look.dp(22));
        box.addView(Look.text(this, console != null ? t("registration").replace("%@", console[1]) : t("loginPin"), 15, 600, Look.TEXT));
        box.addView(Look.text(this, console != null ? t("pairSteps") : t("loginPinNote"), 15, 400, Look.white(0.6)));
        EditText code = new EditText(this);
        code.setInputType(InputType.TYPE_CLASS_NUMBER);
        code.setFilters(new InputFilter[] { new InputFilter.LengthFilter(console != null ? 8 : 4) });
        code.setHint(console != null ? t("pinHint") : t("pinShort"));
        code.setTextColor(Look.TEXT);
        code.setHintTextColor(Look.white(0.4));
        code.setTypeface(Typeface.MONOSPACE);
        code.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 18);
        code.setBackground(Look.rounded(Look.white(0.1), 10));
        code.setPadding(Look.dp(12), Look.dp(8), Look.dp(12), Look.dp(8));
        box.addView(code, Look.fill());
        LinearLayout buttons = Look.row(this, 10);
        buttons.setGravity(Gravity.END);
        if (console != null) {
            TextView cancel = Look.quiet(this, t("cancel"), false);
            cancel.setOnClickListener(view -> { registering = null; hideKeyboard(code); drawn.remove("dialogs"); show(); });
            buttons.addView(cancel);
        }
        TextView done = Look.quiet(this, console != null ? t("register") : t("confirm"), true);
        Look.enable(done, false);
        code.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable text) { Look.enable(done, console == null || text.length() == 8); }
        });
        done.setOnClickListener(view -> {
            hideKeyboard(code);
            if (console != null) { Shared.act("register", console[0] + "|" + code.getText()); registering = null; drawn.remove("dialogs"); show(); }
            else Shared.act("loginPin", code.getText().toString());
        });
        buttons.addView(done);
        box.addView(buttons, Look.fill());
        dialogLayer.addView(box, Look.margins(Look.at(Look.dp(Math.min(380, width - 32)), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL), 0, 60, 0, 0));
        code.post(() -> { code.requestFocus(); ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(code, InputMethodManager.SHOW_IMPLICIT); });
    }

    void target(String part, View view, String id, double corner) {
        Map<String, View> places = targets.get(part);
        if (places == null) { places = new LinkedHashMap<>(); targets.put(part, places); }
        places.put(id, view);
        corners.put(view, (float) corner);
    }
    void clear(String part) {
        Map<String, View> places = targets.remove(part);
        if (places != null) for (View view : places.values()) corners.remove(view);
    }

    private Map<String, View> active() {
        Map<String, View> places = new LinkedHashMap<>();
        String[] parts;
        if (choicesLayer.getVisibility() == View.VISIBLE || dialogLayer.getVisibility() == View.VISIBLE || messageLayer.getVisibility() == View.VISIBLE) parts = new String[0];
        else if (loginLayer.getVisibility() == View.VISIBLE) parts = new String[] { "login" };
        else if (settingsLayer.getVisibility() == View.VISIBLE) parts = new String[] { "settings" };
        else if (pageLayer.getVisibility() == View.VISIBLE) parts = new String[] { "page" };
        else parts = new String[] { "header", "heading", "tiles", "consoles" };
        for (String part : parts) { Map<String, View> some = targets.get(part); if (some != null) places.putAll(some); }
        return places;
    }

    private void sendTargets() {
        StringBuilder lines = new StringBuilder();
        int[] at = new int[2];
        for (Map.Entry<String, View> place : active().entrySet()) {
            View view = place.getValue();
            if (!view.isAttachedToWindow() || !view.isShown() || view.getWidth() == 0) continue;
            view.getLocationInWindow(at);
            lines.append(place.getKey()).append(' ').append(Math.round((at[0] + view.getWidth() / 2f) / Look.density)).append(' ').append(Math.round((at[1] + view.getHeight() / 2f) / Look.density)).append('\n');
        }
        String text = lines.toString();
        if (!text.equals(sentTargets)) { sentTargets = text; Shared.act("targets", text); }
        frame.invalidate();
    }

    private void activate(String id) {
        View view = active().get(id);
        if (view == null) return;
        if (view == search.getParent() || id.equals("search")) { if (width >= 850 || searchExpanded) focusSearch(); else view.performClick(); return; }
        view.performClick();
    }

    private void focusFrame() {
        String id = state.isNull("focus") ? null : state.optString("focus");
        View view = id == null || !Pad.connected() ? null : active().get(id);
        frame.follow(view, view == null ? 0 : corners.getOrDefault(view, 12f));
        if (id != null && !id.equals(shownFocus) && view != null) {
            view.requestRectangleOnScreen(new Rect(-Look.dp(24), -Look.dp(24), view.getWidth() + Look.dp(24), view.getHeight() + Look.dp(60)), false);
        }
        shownFocus = id;
    }

    private final class FocusFrame extends View {
        private View on;
        private float corner;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int[] at = new int[2], mine = new int[2];
        private final RectF last = new RectF();
        FocusFrame(Context context) { super(context); paint.setStyle(Paint.Style.STROKE); }
        void follow(View view, float radius) { on = view; corner = radius; invalidate(); }
        @Override protected void onDraw(Canvas canvas) {
            if (on == null || !on.isShown()) { last.setEmpty(); return; }
            on.getLocationInWindow(at);
            getLocationInWindow(mine);
            float left = at[0] - mine[0], top = at[1] - mine[1];
            RectF box = new RectF(left, top, left + on.getWidth() * on.getScaleX(), top + on.getHeight() * on.getScaleY());
            boolean moved = !box.equals(last);
            last.set(box);
            paint.setStrokeWidth(Look.dp(3));
            paint.setColor(Look.CANVAS);
            box.inset(-Look.dp(1.5), -Look.dp(1.5));
            canvas.drawRoundRect(box, Look.dp(corner + 1.5), Look.dp(corner + 1.5), paint);
            paint.setColor(Color.WHITE);
            box.inset(-Look.dp(3), -Look.dp(3));
            canvas.drawRoundRect(box, Look.dp(corner + 4.5), Look.dp(corner + 4.5), paint);
            if (moved) postInvalidateOnAnimation();
        }
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (pad.key(event)) return true;
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean dispatchGenericMotionEvent(MotionEvent event) {
        if (pad.motion(event)) return true;
        return super.dispatchGenericMotionEvent(event);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused) pad.release();
        else show();
    }

    @Override public void onBackPressed() {
        try {
            if (registering != null) { registering = null; drawn.remove("dialogs"); show(); return; }
            if (state.optBoolean("loginOpen")) { Shared.act("loginOpen", "0"); return; }
            if (state.optJSONArray("choices") != null && state.getJSONArray("choices").length() > 0) { Shared.act("choice", "-1"); return; }
            if (!state.isNull("message")) { Shared.act("message"); return; }
            if (state.getJSONObject("settings").getBoolean("open") || state.getBoolean("gameOpen")) { Shared.act("press", "back"); return; }
            if (searchExpanded) { searchExpanded = false; hideKeyboard(search); show(); return; }
            if (state.getString("destination").equals("consoles")) { Shared.act("destination", "cloud"); return; }
        } catch (Exception ignored) {}
        super.onBackPressed();
    }

    private static final class Backdrop extends View {
        private int first = Color.TRANSPARENT, second = Color.TRANSPARENT;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        Backdrop(Context context) { super(context); }
        void set(int one, int two) { if (one != first || two != second) { first = one; second = two; invalidate(); } }
        @Override protected void onDraw(Canvas canvas) {
            float width = getWidth(), height = getHeight();
            canvas.drawColor(Look.CANVAS);
            paint.setShader(new RadialGradient(width * 0.8f, 0, Look.dp(850), Look.faded(first, 0.75), Color.TRANSPARENT, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, width, height, paint);
            paint.setShader(new RadialGradient(width * 0.05f, height * 0.9f, Look.dp(700), Look.faded(second, 0.5), Color.TRANSPARENT, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, width, height, paint);
            paint.setShader(new LinearGradient(0, 0, 0, height, new int[] { Color.TRANSPARENT, Look.faded(Look.CANVAS, 0.55), Look.faded(Look.CANVAS, 0.9) }, null, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, width, height, paint);
            paint.setShader(null);
        }
    }
}
