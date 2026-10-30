package app.con.check;

import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

final class SettingsPanel {
    private SettingsPanel() {}

    static View build(MainActivity screen, JSONObject settings, int width, int height) throws Exception {
        boolean narrow = width < 820;
        String section = settings.getString("section");
        FrameLayout panel = new FrameLayout(screen);
        panel.setBackground(Look.outlined(Look.PANEL, 22, Look.white(0.08), 1));
        Look.round(panel, 22);
        panel.setClickable(true);
        LinearLayout whole = narrow ? Look.column(screen, 0) : Look.row(screen, 0);
        whole.setGravity(Gravity.TOP);
        panel.addView(whole, Look.whole());
        JSONArray sections = settings.getJSONArray("sections");
        if (narrow) {
            Look.Flow tabs = new Look.Flow(screen, 8, 8);
            tabs.setPadding(Look.dp(20), Look.dp(16), Look.dp(20), Look.dp(4));
            for (int index = 0; index < sections.length(); index++) {
                String id = sections.getJSONArray(index).getString(0), title = sections.getJSONArray(index).getString(1);
                boolean chosen = id.equals(section);
                TextView tab = Look.line(screen, title, 14, 500, chosen ? Look.CANVAS : Color.WHITE);
                tab.setGravity(Gravity.CENTER);
                tab.setPadding(Look.dp(14), 0, Look.dp(14), 0);
                tab.setBackground(Look.capsule(chosen ? Color.WHITE : Look.white(0.07)));
                tab.setOnClickListener(view -> Shared.act("section", id));
                tabs.addView(tab, new android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.WRAP_CONTENT, Look.dp(38)));
                screen.target("settings", tab, "settings-tab:" + id, 19);
            }
            whole.addView(tabs, Look.fill());
        } else {
            LinearLayout side = Look.column(screen, 5);
            side.setPadding(Look.dp(18), Look.dp(30), Look.dp(18), Look.dp(30));
            side.setBackgroundColor(Look.white(0.025));
            TextView title = Look.text(screen, screen.t("settings"), 20, 600, Look.TEXT);
            title.setPadding(Look.dp(12), 0, 0, Look.dp(17));
            side.addView(title);
            for (int index = 0; index < sections.length(); index++) {
                String id = sections.getJSONArray(index).getString(0), name = sections.getJSONArray(index).getString(1);
                boolean chosen = id.equals(section);
                TextView tab = Look.line(screen, name, 15, chosen ? 500 : 400, chosen ? Color.rgb(26, 31, 46) : Look.TEXT);
                tab.setGravity(Gravity.CENTER_VERTICAL);
                tab.setPadding(Look.dp(14), 0, Look.dp(14), 0);
                tab.setBackground(Look.rounded(chosen ? Color.WHITE : Color.TRANSPARENT, 12));
                tab.setOnClickListener(view -> Shared.act("section", id));
                side.addView(tab, Look.sized(-1, 44));
                screen.target("settings", tab, "settings-tab:" + id, 12);
            }
            side.addView(new View(screen), new LinearLayout.LayoutParams(1, 0, 1));
            side.addView(Look.text(screen, "Con · " + version(screen), 13, 400, Look.white(0.55)));
            whole.addView(side, new LinearLayout.LayoutParams(Look.dp(220), LinearLayout.LayoutParams.MATCH_PARENT));
        }
        LinearLayout main = Look.column(screen, 0);
        main.setPadding(Look.dp(width < 760 ? 10 : 30), Look.dp(narrow ? 12 : 30), Look.dp(width < 760 ? 10 : 30), 0);
        String sectionTitle = section;
        for (int index = 0; index < sections.length(); index++) if (sections.getJSONArray(index).getString(0).equals(section)) sectionTitle = sections.getJSONArray(index).getString(1);
        LinearLayout top = Look.row(screen, 12);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(Look.dp(10), 0, 0, Look.dp(narrow ? 16 : 22));
        top.addView(Look.text(screen, sectionTitle, 24, 600, Look.TEXT), Look.weighted());
        Look.Icon close = Look.iconButton(screen, "xmark", screen.t("close"));
        close.setOnClickListener(view -> Shared.act("closeSettings"));
        top.addView(close, Look.sized(36, 36));
        screen.target("settings", close, "icon:" + screen.t("close"), 18);
        main.addView(top, Look.fill());
        ScrollView scroll = new ScrollView(screen);
        scroll.setVerticalScrollBarEnabled(false);
        boolean general = section.equals("General");
        LinearLayout rows = Look.column(screen, general ? 0 : 20);
        rows.setPadding(Look.dp(10), Look.dp(6), Look.dp(10), Look.dp(24));
        Rows content = new Rows(screen, settings, rows, narrow, general);
        switch (section) {
            case "General": content.general(); break;
            case "PSN Account": content.account(width); break;
            case "Stream": content.stream(width); break;
            case "Controls": content.controls(); break;
            default: content.about(); break;
        }
        scroll.addView(rows);
        main.addView(scroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        whole.addView(main, narrow ? new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1) : new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        return panel;
    }

    static String version(MainActivity screen) {
        try { return screen.getPackageManager().getPackageInfo(screen.getPackageName(), 0).versionName; } catch (Exception none) { return ""; }
    }

    private static final class Rows {
        final MainActivity screen;
        final JSONObject settings;
        final LinearLayout rows;
        final boolean narrow, lined;
        Rows(MainActivity screen, JSONObject settings, LinearLayout rows, boolean narrow, boolean lined) {
            this.screen = screen; this.settings = settings; this.rows = rows; this.narrow = narrow; this.lined = lined;
        }
        String t(String key) { return screen.t(key); }

        void row(String title, String caption, View control, boolean last) {
            LinearLayout row = narrow ? Look.column(screen, 14) : Look.row(screen, 20);
            row.setPadding(0, Look.dp(lined ? 18 : 8), 0, Look.dp(lined ? 18 : 8));
            LinearLayout label = Look.column(screen, 5);
            label.addView(Look.text(screen, title, 15, 600, Look.TEXT));
            label.addView(Look.text(screen, caption, 13, 400, Look.white(0.55)));
            row.addView(label, narrow ? Look.fill() : Look.weighted());
            row.addView(control, control.getLayoutParams() != null ? (LinearLayout.LayoutParams) control.getLayoutParams() : Look.wrap());
            rows.addView(row, Look.fill());
            if (lined && !last) {
                View line = new View(screen);
                line.setBackgroundColor(Look.white(0.07));
                rows.addView(line, Look.sized(-1, 1));
            }
        }

        View select(String name, String label, double width, boolean enabled) throws Exception {
            LinearLayout select = Look.row(screen, 8);
            select.setPadding(Look.dp(12), 0, Look.dp(12), 0);
            select.setBackground(Look.rounded(Look.white(0.1), 10));
            TextView chosen = Look.line(screen, settings.getJSONObject("selects").optString(name, label), 14, 400, Color.WHITE);
            select.addView(chosen, Look.weighted());
            select.addView(new Look.Icon(screen, "chevron.down", Look.white(0.65)), Look.sized(10, 10));
            select.setOnClickListener(view -> Shared.act("select", name));
            Look.pressable(select);
            Look.enable(select, enabled);
            select.setContentDescription(label);
            select.setLayoutParams(Look.sized(width, 36));
            screen.target("settings", select, "select:" + name, 10);
            return select;
        }

        void general() throws Exception {
            row(t("appLanguage"), t("appLanguageCaption"), select("app-language", t("appLanguage"), 200, true), false);
            row(t("region"), t("regionCaption"), select("catalog-locale", t("region"), 200, true), false);
            row(t("fit"), t("fitCaption"), select("video-fit", t("fit"), 200, true), true);
        }

        void account(int width) throws Exception {
            JSONObject state = screen.state;
            boolean signedIn = !state.isNull("account"), restoring = state.getBoolean("restoring");
            LinearLayout card = Look.row(screen, 15);
            card.setPadding(Look.dp(22), Look.dp(22), Look.dp(22), Look.dp(22));
            card.setBackground(Look.rounded(Look.white(0.05), 16));
            card.addView(screen.avatar(64, signedIn), Look.sized(64, 64));
            LinearLayout words = Look.column(screen, 5);
            words.addView(Look.text(screen, signedIn ? state.getString("account") : t("yourAccount"), 20, 600, Look.TEXT));
            words.addView(Look.text(screen, settings.getString("accountNote"), 14, 400, Look.white(0.55)));
            card.addView(words, Look.weighted());
            rows.addView(card, Look.fill());
            LinearLayout buttons = Look.row(screen, 12);
            if (signedIn) {
                TextView refresh = Look.quiet(screen, t("refreshSignIn"), true);
                refresh.setOnClickListener(view -> { Shared.act("closeSettings"); Shared.act("loginOpen", "1"); });
                buttons.addView(refresh);
                screen.target("settings", refresh, "account-refresh", 21);
            }
            TextView main = Look.quiet(screen, settings.getString("accountButton"), !signedIn);
            if (signedIn) main.setTextColor(Look.DANGER);
            main.setOnClickListener(view -> { if (signedIn) Shared.act("signOut"); else { Shared.act("closeSettings"); Shared.act("loginOpen", "1"); } });
            Look.enable(main, !restoring && !state.getBoolean("signingOut"));
            buttons.addView(main);
            screen.target("settings", main, "account-login", 21);
            rows.addView(buttons);
            if (!signedIn && !restoring && !state.isNull("authError")) rows.addView(Look.text(screen, state.getString("authError"), 15, 400, Look.ACCENT));
            TextView footer = Look.text(screen, t("accountFooter"), 14, 400, Look.white(0.55));
            footer.setLineSpacing(Look.dp(5), 1);
            rows.addView(footer);
            JSONObject page = settings.getJSONObject("accountPage");
            if (page.getBoolean("shown")) accountPage(page, width);
        }

        void accountPage(JSONObject page, int width) throws Exception {
            divider();
            LinearLayout trophies = Look.column(screen, 12);
            trophies.addView(Look.text(screen, t("trophies"), 15, 500, Look.TEXT));
            if (page.has("level")) {
                LinearLayout card = narrow ? Look.column(screen, 18) : Look.row(screen, 16);
                card.setPadding(Look.dp(18), Look.dp(18), Look.dp(18), Look.dp(18));
                card.setBackground(Look.rounded(Look.white(0.05), 16));
                LinearLayout top = Look.row(screen, 16);
                FrameLayout badge = new FrameLayout(screen);
                badge.setBackground(Look.capsule(Look.white(0.06)));
                badge.addView(new Look.Icon(screen, "trophy", page.getInt("gold")), Look.at(Look.dp(24), Look.dp(24), Gravity.CENTER));
                top.addView(badge, Look.sized(52, 52));
                LinearLayout level = Look.column(screen, 7);
                level.addView(Look.text(screen, page.getString("level"), 18, 600, Look.TEXT));
                level.addView(bar(page.getInt("progress")), Look.sized(200, 4));
                TextView progress = Look.text(screen, page.getString("progressText"), 12, 400, Look.white(0.55));
                progress.setFontFeatureSettings("tnum");
                level.addView(progress);
                top.addView(level, narrow ? Look.weighted() : Look.wrap());
                card.addView(top, narrow ? Look.fill() : Look.weighted());
                LinearLayout grades = Look.row(screen, 0);
                JSONArray list = page.getJSONArray("grades");
                for (int index = 0; index < list.length(); index++) {
                    JSONObject grade = list.getJSONObject(index);
                    LinearLayout one = Look.column(screen, 4);
                    one.setGravity(Gravity.CENTER_HORIZONTAL);
                    one.addView(new Look.Icon(screen, "trophy", grade.getInt("tint")), Look.sized(16, 16));
                    TextView count = Look.text(screen, String.valueOf(grade.getInt("count")), 15, 600, Look.TEXT);
                    count.setFontFeatureSettings("tnum");
                    one.addView(count);
                    one.addView(Look.line(screen, grade.getString("title"), 11, 400, Look.white(0.55)));
                    grades.addView(one, Look.sized(64, -2));
                }
                card.addView(grades, Look.wrap());
                trophies.addView(card, Look.fill());
            }
            JSONArray titles = page.getJSONArray("titles");
            for (int index = 0; index < titles.length(); index++) {
                JSONObject title = titles.getJSONObject(index);
                LinearLayout row = Look.row(screen, 12);
                FrameLayout icon = new FrameLayout(screen);
                icon.setBackground(Look.rounded(Look.white(0.06), 9));
                icon.addView(new Look.Icon(screen, "trophy", Look.white(0.45)), Look.at(Look.dp(18), Look.dp(18), Gravity.CENTER));
                ImageView picture = new ImageView(screen);
                picture.setScaleType(ImageView.ScaleType.CENTER_CROP);
                icon.addView(picture, Look.whole());
                Images.show(picture, title.isNull("icon") ? null : title.getString("icon"), 160);
                Look.round(icon, 9);
                row.addView(icon, Look.sized(44, 44));
                LinearLayout words = Look.column(screen, 3);
                words.addView(Look.line(screen, title.getString("name"), 14, 500, Look.TEXT));
                words.addView(Look.line(screen, title.getString("note"), 12, 400, Look.white(0.55)));
                row.addView(words, Look.weighted());
                LinearLayout done = Look.column(screen, 6);
                done.setGravity(Gravity.END);
                TextView percent = Look.text(screen, title.getInt("progress") + "%", 13, 600, Look.TEXT);
                percent.setFontFeatureSettings("tnum");
                done.addView(percent);
                done.addView(bar(title.getInt("progress")), Look.sized(80, 4));
                row.addView(done);
                trophies.addView(row, Look.fill());
            }
            if (!page.isNull("trophyNote")) trophies.addView(Look.text(screen, page.getString("trophyNote"), 13, 400, Look.white(0.55)));
            rows.addView(trophies, Look.fill());

            LinearLayout recent = Look.column(screen, 12);
            recent.addView(Look.text(screen, t("recentGames"), 15, 500, Look.TEXT));
            if (!page.isNull("recentNote")) recent.addView(Look.text(screen, page.getString("recentNote"), 13, 400, Look.white(0.55)));
            double room = (narrow ? width : width - 220) - 2 * (width < 760 ? 10 : 30) - 20;
            int across = Math.max(2, (int) ((room + 14) / (112 + 14)));
            double tile = Math.min(150, (room - 14 * (across - 1)) / across);
            Look.Flow grid = new Look.Flow(screen, 14, 16);
            JSONArray games = page.getJSONArray("recent");
            for (int index = 0; index < games.length(); index++) {
                JSONObject game = games.getJSONObject(index);
                String id = game.getString("id");
                LinearLayout one = Look.column(screen, 7);
                one.addView(screen.cover(game, 12, 24), Look.sized(tile, tile));
                TextView name = Look.text(screen, game.getString("title"), 13, 600, Look.TEXT);
                name.setMaxLines(2);
                name.setEllipsize(android.text.TextUtils.TruncateAt.END);
                one.addView(name, Look.fill());
                if (!game.isNull("played")) one.addView(Look.line(screen, game.getString("played"), 12, 400, Look.white(0.55)));
                one.setContentDescription(game.getString("title"));
                one.setOnClickListener(view -> Shared.act("openRecent", id));
                Look.pressable(one);
                grid.addView(one, new android.view.ViewGroup.LayoutParams(Look.dp(tile), android.view.ViewGroup.LayoutParams.WRAP_CONTENT));
                screen.target("settings", one, "recent:" + id, 12);
            }
            recent.addView(grid, Look.fill());
            rows.addView(recent, Look.fill());
        }

        View bar(int percent) {
            LinearLayout track = Look.row(screen, 0);
            track.setBackground(Look.capsule(Look.white(0.12)));
            View filled = new View(screen);
            filled.setBackground(Look.capsule(Look.ACCENT));
            track.addView(filled, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, Math.max(1, Math.min(100, percent))));
            track.addView(new View(screen), new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, Math.max(0, 100 - percent)));
            return track;
        }

        void stream(int width) throws Exception {
            LinearLayout quality = Look.column(screen, 12);
            quality.addView(Look.text(screen, t("quality"), 15, 500, Look.TEXT));
            JSONArray presets = settings.getJSONArray("presets");
            int across = width < 650 ? 2 : width < 900 ? 3 : 6;
            LinearLayout grid = Look.column(screen, 10);
            LinearLayout line = null;
            for (int index = 0; index < presets.length(); index++) {
                JSONArray preset = presets.getJSONArray(index);
                int heightValue = preset.getInt(0);
                boolean chosen = heightValue == settings.getInt("resolution");
                if (index % across == 0) { line = Look.row(screen, 10); grid.addView(line, Look.fill()); }
                LinearLayout tile = Look.column(screen, 5);
                tile.setGravity(Gravity.CENTER);
                tile.setBackground(Look.outlined(chosen ? Look.white(0.1) : Look.white(0.05), 14, chosen ? Color.WHITE : Look.white(0.08), 2));
                TextView name = Look.text(screen, preset.getString(1), 17, 700, Look.TEXT);
                name.setGravity(Gravity.CENTER);
                tile.addView(name, Look.wrap());
                TextView note = Look.line(screen, preset.getString(2), 12, 400, Look.white(0.55));
                note.setGravity(Gravity.CENTER);
                tile.addView(note, Look.wrap());
                tile.setOnClickListener(view -> Shared.act("preset", String.valueOf(heightValue)));
                Look.pressable(tile);
                line.addView(tile, new LinearLayout.LayoutParams(0, Look.dp(72), 1));
                screen.target("settings", tile, "quality:" + heightValue, 14);
            }
            quality.addView(grid, Look.fill());
            rows.addView(quality, Look.fill());

            LinearLayout rate = Look.column(screen, 3);
            rate.setGravity(narrow ? Gravity.START : Gravity.END);
            TextView value = Look.text(screen, settings.getString("bitrateText"), 13, 400, Look.white(0.55));
            rate.addView(value);
            SeekBar slider = new SeekBar(screen);
            slider.setMax(75);
            slider.setProgress(settings.getInt("bitrate") - 5);
            slider.getProgressDrawable().setTint(Look.ACCENT);
            slider.getThumb().setTint(Color.WHITE);
            String unit = settings.getString("bitrateText").replaceFirst("^\\d+", "");
            slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                public void onProgressChanged(SeekBar bar, int progress, boolean byUser) { value.setText((progress + 5) + unit); }
                public void onStartTrackingTouch(SeekBar bar) {}
                public void onStopTrackingTouch(SeekBar bar) { Shared.act("bitrate", String.valueOf(bar.getProgress() + 5)); }
            });
            rate.addView(slider, Look.sized(narrow ? -1 : 260, 32));
            rate.setLayoutParams(narrow ? Look.fill() : Look.wrap());
            row(t("bitrate"), t("bitrateCaption"), rate, true);
            screen.target("settings", slider, "bitrate", 8);
            row(t("even"), t("evenCaption"), select("smoothness", t("even"), 200, true), true);
            View trophies = Look.toggle(screen, settings.optBoolean("trophyNotices", true));
            trophies.setOnClickListener(view -> Shared.act("trophyNotices", settings.optBoolean("trophyNotices", true) ? "0" : "1"));
            row(t("trophyNotices"), t("trophyNoticesCaption"), trophies, true);
            screen.target("settings", trophies, "toggle:" + t("trophyNotices"), 14);
            View distant = Look.toggle(screen, settings.optBoolean("distantServers", false));
            distant.setOnClickListener(view -> Shared.act("distantServers", settings.optBoolean("distantServers", false) ? "0" : "1"));
            row(t("distantServers"), t("distantServersCaption"), distant, true);
            screen.target("settings", distant, "toggle:" + t("distantServers"), 14);

            divider();
            boolean known = settings.getBoolean("datacenters");
            row(t("datacenter"), settings.getString("datacenterCaption"), select("datacenter", t("datacenter"), Math.min(260, screen.width - 80), known), true);
            rows.addView(Look.text(screen, settings.getString("datacenterNote"), 13, 400, Look.white(0.55)));
            if (screen.state.optBoolean("canRetry") && !screen.state.isNull("account")) {
                TextView retry = Look.text(screen, t("retry"), 12, 400, Look.ACCENT);
                retry.setOnClickListener(view -> { Shared.act("closeSettings"); Shared.act("retry"); });
                rows.addView(retry);
                screen.target("settings", retry, "retry", 6);
            }
            divider();
            row(t("gameLanguage"), t("gameLanguageCaption"), select("game-language", t("gameLanguage"), 200, true), true);
        }

        void divider() {
            View line = new View(screen);
            line.setBackgroundColor(Look.white(0.12));
            rows.addView(line, Look.sized(-1, 1));
        }

        void controls() throws Exception {
            java.util.List<String> pads = Pad.names();
            LinearLayout list = Look.column(screen, 16);
            if (pads.isEmpty()) {
                LinearLayout title = Look.row(screen, 8);
                title.addView(new Look.Icon(screen, "gamecontroller", Look.TEXT), Look.sized(20, 20));
                title.addView(Look.text(screen, t("noPad"), 15, 500, Look.TEXT));
                list.addView(title);
                list.addView(Look.text(screen, t("noPadNote"), 14, 400, Look.white(0.55)));
            }
            for (String name : pads) {
                LinearLayout card = Look.column(screen, 12);
                card.setPadding(Look.dp(22), Look.dp(20), Look.dp(22), Look.dp(20));
                card.setBackground(Look.rounded(Look.white(0.05), 16));
                LinearLayout title = Look.row(screen, 8);
                title.addView(new Look.Icon(screen, "gamecontroller", Look.ACCENT), Look.sized(20, 20));
                title.addView(Look.text(screen, name, 16, 600, Look.TEXT));
                card.addView(title);
                if (!screen.state.isNull("held")) {
                    TextView held = Look.text(screen, screen.state.getString("held"), 14, 400, Look.ACCENT);
                    held.setTypeface(android.graphics.Typeface.MONOSPACE);
                    card.addView(held);
                }
                list.addView(card, Look.fill());
            }
            list.addView(Look.text(screen, t("padNote"), 13, 400, Look.white(0.4)));
            rows.addView(list, Look.fill());
            View touch = Look.toggle(screen, settings.optBoolean("touchGamepad", true));
            touch.setOnClickListener(view -> Shared.act("touchGamepad", settings.optBoolean("touchGamepad", true) ? "0" : "1"));
            row(t("touchGamepad"), t("touchGamepadCaption"), touch, true);
            screen.target("settings", touch, "toggle:" + t("touchGamepad"), 14);
            View toggle = Look.toggle(screen, settings.getBoolean("haptics"));
            toggle.setOnClickListener(view -> Shared.act("haptics", settings.optBoolean("haptics") ? "0" : "1"));
            row(t("haptics"), t("hapticsCaption"), toggle, true);
            screen.target("settings", toggle, "toggle:" + t("haptics"), 14);
        }

        void about() {
            LinearLayout about = Look.column(screen, 16);
            about.addView(Look.logo(screen, 84), Look.sized(84, 84));
            about.addView(Look.text(screen, "Con", 40, 600, Look.TEXT));
            about.addView(Look.text(screen, t("tagline"), 18, 400, Look.white(0.55)));
            about.addView(Look.text(screen, t("version").replace("%@", version(screen)), 13, 400, Look.white(0.4)));
            View line = new View(screen);
            line.setBackgroundColor(Look.white(0.12));
            about.addView(line, Look.margins(Look.sized(-1, 1), 0, 5, 0, 5));
            about.addView(Look.text(screen, t("aboutNote"), 14, 400, Look.white(0.55)));
            TextView licenses = Look.text(screen, t("licenses"), 14, 400, Look.ACCENT);
            licenses.setOnClickListener(view -> Notices.show(screen));
            about.addView(licenses);
            screen.target("settings", licenses, "about-licenses", 6);
            rows.addView(about, Look.fill());
        }
    }
}
