package app.con.check;

import android.app.Dialog;
import android.view.Gravity;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

final class Notices {
    private Notices() {}

    static void show(MainActivity screen) {
        String text;
        try (InputStream in = screen.getAssets().open("THIRD-PARTY-NOTICES.md")) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            for (int read; (read = in.read(chunk)) > 0; ) bytes.write(chunk, 0, read);
            text = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception missing) {
            text = "—";
        }
        Dialog dialog = new Dialog(screen, android.R.style.Theme_Material_NoActionBar_Fullscreen);
        LinearLayout page = Look.column(screen, 0);
        page.setBackgroundColor(Look.PANEL);
        FrameLayout top = new FrameLayout(screen);
        top.setPadding(Look.dp(20), Look.dp(16), Look.dp(16), Look.dp(8));
        top.addView(Look.text(screen, screen.t("licenses"), 20, 600, Look.TEXT), Look.at(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.START | Gravity.CENTER_VERTICAL));
        Look.Icon close = Look.iconButton(screen, "xmark", screen.t("close"));
        close.setOnClickListener(view -> dialog.dismiss());
        top.addView(close, Look.at(Look.dp(36), Look.dp(36), Gravity.END | Gravity.CENTER_VERTICAL));
        page.addView(top, Look.fill());
        ScrollView scroll = new ScrollView(screen);
        TextView body = Look.text(screen, text, 12, 400, Look.white(0.75));
        body.setTypeface(android.graphics.Typeface.MONOSPACE);
        body.setTextIsSelectable(true);
        body.setPadding(Look.dp(20), Look.dp(8), Look.dp(20), Look.dp(40));
        scroll.addView(body);
        page.addView(scroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        page.setFitsSystemWindows(true);
        dialog.setContentView(page);
        dialog.show();
    }
}
