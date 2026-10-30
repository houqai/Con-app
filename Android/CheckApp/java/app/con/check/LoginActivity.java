package app.con.check;

import android.app.Activity;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebStorage;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class LoginActivity extends Activity {
    static final String ADDRESS = "address", SCHEME = "scheme";
    private static final String ACCOUNT_SITE = "ca.account.sony.com";
    private static LoginActivity open;
    private WebView page;
    private boolean answered;

    static void closeOpen() {
        if (open != null) { open.answered = true; open.finish(); }
    }

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        final String address = getIntent().getStringExtra(ADDRESS), scheme = getIntent().getStringExtra(SCHEME);
        Uri start = address == null ? null : Uri.parse(address);
        if (start == null || scheme == null || !"https".equals(start.getScheme()) || !ACCOUNT_SITE.equals(start.getHost())) { finish(); return; }
        open = this;
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Look.CANVAS);
        final TextView host = new TextView(this);
        host.setTextColor(Color.rgb(170, 176, 190));
        host.setTextSize(13);
        host.setGravity(android.view.Gravity.CENTER);
        int edge = (int) (10 * getResources().getDisplayMetrics().density);
        host.setPadding(edge, edge * 3, edge, edge);
        host.setText(ACCOUNT_SITE);
        page = new WebView(this);
        page.getSettings().setJavaScriptEnabled(true);
        page.getSettings().setDomStorageEnabled(true);
        page.getSettings().setSupportMultipleWindows(false);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(page, true);
        page.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri next = request.getUrl();
                if (scheme.equals(next.getScheme())) {
                    CookieManager cookies = CookieManager.getInstance();
                    String securely = cookies.getCookie("https://" + ACCOUNT_SITE + "/"), plainly = cookies.getCookie("http://" + ACCOUNT_SITE + "/");
                    answered = true;
                    Shared.loginFinished(next.toString(), securely == null ? "" : securely, plainly == null ? "" : plainly);
                    finish();
                    return true;
                }
                if (!"https".equals(next.getScheme()) && !"about:blank".equals(next.toString())) return true;
                if (request.isForMainFrame() && next.getHost() != null) host.setText(next.getHost());
                return false;
            }
            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse answer) {
                note("HTTP " + answer.getStatusCode(), request);
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                note("failed (" + error.getDescription() + ")", request);
            }
        });
        root.addView(host);
        root.addView(page, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);
        WebStorage.getInstance().deleteAllData();
        CookieManager.getInstance().removeAllCookies(done -> { if (open == LoginActivity.this && page != null) page.loadUrl(address); });
    }

    private void forget() {
        CookieManager.getInstance().removeAllCookies(null);
        CookieManager.getInstance().flush();
        WebStorage.getInstance().deleteAllData();
    }

    private static void note(String how, WebResourceRequest request) {
        Uri to = request.getUrl();
        Log.i(MainActivity.TAG, "sign-in page: " + how + " " + request.getMethod() + " " + to.getHost() + to.getPath() + (request.isForMainFrame() ? " (the page itself)" : ""));
    }

    @Override protected void onDestroy() {
        if (page != null) {
            page.stopLoading();
            page.clearCache(true);
            page.clearHistory();
            page.destroy();
            forget();
        }
        if (open == this) open = null;
        if (!answered && isFinishing()) Shared.loginClosed();
        super.onDestroy();
    }
}
