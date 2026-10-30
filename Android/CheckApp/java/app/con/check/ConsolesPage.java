package app.con.check;

import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

final class ConsolesPage {
    private ConsolesPage() {}

    static View build(MainActivity screen, JSONObject consoles) throws Exception {
        ScrollView scroll = new ScrollView(screen);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout column = Look.column(screen, 12);
        column.setPadding(Look.dp(24), Look.dp(screen.width < 850 ? 32 : 80), Look.dp(24), Look.dp(40));
        TextView title = Look.text(screen, screen.t("consolesTitle"), screen.width < 850 ? 36 : 52, 700, Look.TEXT);
        title.setLetterSpacing(-0.025f);
        column.addView(title);
        TextView note = Look.text(screen, screen.t("consolesNote"), 18, 400, Look.TEXT);
        note.setAlpha(0.7f);
        column.addView(note);
        LinearLayout list = Look.column(screen, 14);
        list.setPadding(0, Look.dp(42), 0, 0);
        JSONObject state = screen.state;
        boolean signedIn = !state.isNull("account"), busy = consoles.getBoolean("busy");
        if (!signedIn) list.addView(banner(screen, screen.t("consolesSignIn"), Look.ACCENT, screen.t("connectPSButton"), () -> Shared.act("loginOpen", "1")));
        if (!consoles.isNull("status")) list.addView(banner(screen, consoles.getString("status"), Look.ACCENT, null, null));
        if (!consoles.isNull("failure")) list.addView(banner(screen, consoles.getString("failure"), Color.rgb(255, 159, 10), "×", () -> Shared.act("clearFailure")));
        JSONArray found = consoles.getJSONArray("found");
        LinearLayout heading = Look.row(screen, 8);
        heading.addView(new Look.Icon(screen, "waves", Look.ACCENT), Look.sized(18, 18));
        heading.addView(Look.text(screen, screen.t("local"), 16, 600, Look.TEXT));
        if (found.length() == 0) {
            ProgressBar spinner = new ProgressBar(screen);
            spinner.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(Look.white(0.6)));
            heading.addView(spinner, Look.sized(16, 16));
        }
        list.addView(heading, Look.margins(Look.wrap(), 0, 4, 0, 0));
        if (found.length() == 0) list.addView(Look.text(screen, screen.t("searching"), 15, 400, Look.white(0.55)));
        for (int index = 0; index < found.length(); index++) list.addView(console(screen, found.getJSONObject(index), signedIn, busy), Look.fill());
        JSONArray offline = consoles.getJSONArray("offline");
        if (offline.length() > 0) {
            list.addView(Look.text(screen, screen.t("saved"), 16, 600, Look.TEXT), Look.margins(Look.wrap(), 0, 10, 0, 0));
            for (int index = 0; index < offline.length(); index++) list.addView(saved(screen, offline.getJSONObject(index)), Look.fill());
        }
        TextView remote = Look.text(screen, screen.t("remoteNote"), 13, 400, Look.white(0.4));
        list.addView(remote, Look.margins(Look.fill(), 0, 10, 0, 0));
        column.addView(list, Look.fill());
        scroll.addView(column);
        return scroll;
    }

    private static View banner(MainActivity screen, String text, int tint, String action, Runnable perform) {
        LinearLayout banner = Look.row(screen, 10);
        banner.setPadding(Look.dp(13), Look.dp(13), Look.dp(13), Look.dp(13));
        banner.setBackground(Look.rounded(Look.faded(tint, 0.1), 9));
        banner.addView(Look.text(screen, text, 15, 400, Look.white(0.6)), Look.weighted());
        if (action != null && perform != null) {
            TextView button = Look.quiet(screen, action, false);
            button.setOnClickListener(view -> perform.run());
            banner.addView(button);
            screen.target("consoles", button, "banner:" + action, 21);
        }
        return banner;
    }

    private static View console(MainActivity screen, JSONObject console, boolean signedIn, boolean busy) throws Exception {
        String id = console.getString("id"), name = console.getString("name");
        boolean registered = console.getBoolean("registered");
        LinearLayout row = Look.row(screen, 14);
        row.setPadding(Look.dp(15), Look.dp(15), Look.dp(15), Look.dp(15));
        row.setBackground(Look.rounded(Look.white(0.05), 10));
        row.addView(new Look.Icon(screen, "gamecontroller", Look.ACCENT), Look.sized(28, 28));
        LinearLayout words = Look.column(screen, 3);
        words.addView(Look.line(screen, name, 14, 500, Look.TEXT));
        LinearLayout facts = Look.row(screen, 6);
        facts.addView(Look.text(screen, console.getBoolean("ps5") ? "PS5" : "PS4", 10, 600, Look.white(0.55)));
        JSONArray state = console.getJSONArray("state");
        int colour = state.getInt(1) == 0 ? Color.rgb(52, 199, 89) : state.getInt(1) == 1 ? Color.rgb(255, 214, 10) : Color.GRAY;
        TextView badge = Look.text(screen, state.getString(0), 10, 500, colour);
        badge.setPadding(Look.dp(7), Look.dp(2), Look.dp(7), Look.dp(2));
        badge.setBackground(Look.capsule(Look.faded(colour, 0.14)));
        facts.addView(badge);
        words.addView(facts);
        row.addView(words, Look.weighted());
        if (registered) {
            TextView play = Look.quiet(screen, screen.t("play"), true);
            play.setOnClickListener(view -> Shared.act("connectConsole", id));
            Look.enable(play, !busy && signedIn);
            row.addView(play);
            screen.target("consoles", play, "console-play:" + id, 21);
            Look.Icon more = new Look.Icon(screen, "ellipsis", Look.white(0.7));
            more.setPadding(Look.dp(4), Look.dp(4), Look.dp(4), Look.dp(4));
            more.setOnClickListener(view -> {
                android.widget.PopupMenu menu = new android.widget.PopupMenu(screen, view);
                menu.getMenu().add(screen.t("unregister"));
                menu.setOnMenuItemClickListener(item -> { Shared.act("removeConsole", id); return true; });
                menu.show();
            });
            more.setContentDescription(screen.t("unregister"));
            row.addView(more, Look.sized(30, 30));
        } else {
            TextView pair = Look.quiet(screen, screen.t("pair"), false);
            pair.setOnClickListener(view -> screen.register(id, name));
            Look.enable(pair, !busy && signedIn);
            row.addView(pair);
            screen.target("consoles", pair, "console-register:" + id, 21);
        }
        return row;
    }

    private static View saved(MainActivity screen, JSONObject entry) throws Exception {
        String id = entry.getString("id");
        LinearLayout row = Look.row(screen, 14);
        row.setPadding(Look.dp(15), Look.dp(15), Look.dp(15), Look.dp(15));
        row.setBackground(Look.rounded(Look.white(0.05), 10));
        row.setAlpha(0.7f);
        row.addView(new Look.Icon(screen, "gamecontroller", Look.white(0.4)), Look.sized(28, 28));
        LinearLayout words = Look.column(screen, 3);
        words.addView(Look.line(screen, entry.getString("name"), 14, 500, Look.TEXT));
        words.addView(Look.text(screen, screen.t("offline"), 10, 400, Look.white(0.4)));
        row.addView(words, Look.weighted());
        TextView remove = Look.quiet(screen, screen.t("remove"), false);
        remove.setTextColor(Look.DANGER);
        remove.setOnClickListener(view -> Shared.act("removeConsole", id));
        row.addView(remove);
        screen.target("consoles", remove, "console-remove:" + id, 21);
        return row;
    }
}
