package app.con.check;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

final class Look {
    private Look() {}

    static final int CANVAS = Color.rgb(7, 10, 20);
    static final int ACCENT = Color.rgb(143, 181, 255);
    static final int TEXT = Color.rgb(244, 246, 251);
    static final int PANEL = Color.rgb(18, 21, 34);
    static final int DANGER = Color.rgb(255, 138, 128);
    static final int RED = Color.rgb(219, 64, 69);

    static int white(double opacity) { return Color.argb((int) Math.round(opacity * 255), 255, 255, 255); }
    static int black(double opacity) { return Color.argb((int) Math.round(opacity * 255), 0, 0, 0); }
    static int faded(int colour, double opacity) { return Color.argb((int) Math.round(opacity * 255), Color.red(colour), Color.green(colour), Color.blue(colour)); }

    static float density = 1;
    static int dp(double value) { return (int) Math.round(value * density); }

    static GradientDrawable capsule(int fill) { return rounded(fill, 999); }
    static GradientDrawable rounded(int fill, double radius) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(fill);
        shape.setCornerRadius(dp(radius));
        return shape;
    }
    static GradientDrawable outlined(int fill, double radius, int line, double width) {
        GradientDrawable shape = rounded(fill, radius);
        shape.setStroke(Math.max(1, dp(width)), line);
        return shape;
    }

    static TextView text(Context context, String words, double size, int weight, int colour) {
        TextView text = new TextView(context);
        text.setText(words);
        text.setTextSize(TypedValue.COMPLEX_UNIT_DIP, (float) size);
        text.setTextColor(colour);
        text.setTypeface(Typeface.create(Typeface.DEFAULT, weight, false));
        text.setIncludeFontPadding(false);
        return text;
    }
    static TextView line(Context context, String words, double size, int weight, int colour) {
        TextView text = text(context, words, size, weight, colour);
        text.setSingleLine(true);
        text.setEllipsize(TextUtils.TruncateAt.END);
        return text;
    }

    static void round(View view, double radius) {
        final float corner = dp(radius);
        view.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View shape, Outline outline) { outline.setRoundRect(0, 0, shape.getWidth(), shape.getHeight(), corner); }
        });
        view.setClipToOutline(true);
    }

    static LinearLayout row(Context context, double spacing) {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        if (spacing > 0) {
            row.setDividerDrawable(gap(spacing, 0));
            row.setShowDividers(LinearLayout.SHOW_DIVIDER_MIDDLE);
        }
        return row;
    }
    static LinearLayout column(Context context, double spacing) {
        LinearLayout column = new LinearLayout(context);
        column.setOrientation(LinearLayout.VERTICAL);
        if (spacing > 0) {
            column.setDividerDrawable(gap(0, spacing));
            column.setShowDividers(LinearLayout.SHOW_DIVIDER_MIDDLE);
        }
        return column;
    }
    private static GradientDrawable gap(double width, double height) {
        GradientDrawable gap = new GradientDrawable();
        gap.setColor(Color.TRANSPARENT);
        gap.setSize(dp(width), dp(height));
        return gap;
    }

    static LinearLayout.LayoutParams wrap() { return new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT); }
    static LinearLayout.LayoutParams fill() { return new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT); }
    static LinearLayout.LayoutParams sized(double width, double height) { return new LinearLayout.LayoutParams(width < 0 ? (int) width : dp(width), height < 0 ? (int) height : dp(height)); }
    static LinearLayout.LayoutParams weighted() { return new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1); }
    static FrameLayout.LayoutParams whole() { return new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT); }
    static FrameLayout.LayoutParams at(int width, int height, int gravity) { return new FrameLayout.LayoutParams(width, height, gravity); }
    static <T extends android.view.ViewGroup.MarginLayoutParams> T margins(T params, double left, double top, double right, double bottom) {
        params.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return params;
    }

    static final class Flow extends android.view.ViewGroup {
        private final int across, down;
        Flow(Context context, double across, double down) { super(context); this.across = dp(across); this.down = dp(down); }
        @Override protected void onMeasure(int widthSpec, int heightSpec) {
            int room = MeasureSpec.getSize(widthSpec) - getPaddingLeft() - getPaddingRight();
            int x = 0, rowHeight = 0, height = 0, widest = 0;
            for (int index = 0; index < getChildCount(); index++) {
                View child = getChildAt(index);
                if (child.getVisibility() == GONE) continue;
                android.view.ViewGroup.LayoutParams wanted = child.getLayoutParams();
                child.measure(wanted.width >= 0 ? MeasureSpec.makeMeasureSpec(wanted.width, MeasureSpec.EXACTLY) : MeasureSpec.makeMeasureSpec(room, MeasureSpec.AT_MOST),
                        wanted.height >= 0 ? MeasureSpec.makeMeasureSpec(wanted.height, MeasureSpec.EXACTLY) : MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
                if (x > 0 && x + child.getMeasuredWidth() > room) { height += rowHeight + down; x = 0; rowHeight = 0; }
                x += child.getMeasuredWidth() + across;
                widest = Math.max(widest, x - across);
                rowHeight = Math.max(rowHeight, child.getMeasuredHeight());
            }
            height += rowHeight;
            setMeasuredDimension(MeasureSpec.getMode(widthSpec) == MeasureSpec.EXACTLY ? MeasureSpec.getSize(widthSpec) : widest + getPaddingLeft() + getPaddingRight(),
                    height + getPaddingTop() + getPaddingBottom());
        }
        @Override protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
            int room = right - left - getPaddingLeft() - getPaddingRight();
            int x = 0, y = 0, rowHeight = 0;
            for (int index = 0; index < getChildCount(); index++) {
                View child = getChildAt(index);
                if (child.getVisibility() == GONE) continue;
                if (x > 0 && x + child.getMeasuredWidth() > room) { y += rowHeight + down; x = 0; rowHeight = 0; }
                child.layout(getPaddingLeft() + x, getPaddingTop() + y, getPaddingLeft() + x + child.getMeasuredWidth(), getPaddingTop() + y + child.getMeasuredHeight());
                x += child.getMeasuredWidth() + across;
                rowHeight = Math.max(rowHeight, child.getMeasuredHeight());
            }
        }
    }

    static TextView quiet(Context context, String words, boolean prominent) {
        TextView button = text(context, words, 15, 600, prominent ? CANVAS : Color.WHITE);
        button.setGravity(Gravity.CENTER);
        button.setPadding(dp(24), 0, dp(24), 0);
        button.setMinHeight(dp(42));
        button.setBackground(capsule(prominent ? Color.WHITE : white(0.12)));
        pressable(button);
        return button;
    }

    static void pressable(View view) {
        view.setClickable(true);
        view.setOnTouchListener((touched, event) -> {
            switch (event.getActionMasked()) {
                case android.view.MotionEvent.ACTION_DOWN: touched.setAlpha(touched.isEnabled() ? 0.7f : touched.getAlpha()); break;
                case android.view.MotionEvent.ACTION_UP: case android.view.MotionEvent.ACTION_CANCEL: touched.setAlpha(touched.isEnabled() ? 1f : 0.4f); break;
            }
            return false;
        });
    }

    static void enable(View view, boolean on) {
        view.setEnabled(on);
        view.setAlpha(on ? 1f : 0.4f);
    }

    static Icon iconButton(Context context, String icon, String help) {
        Icon button = new Icon(context, icon, Color.WHITE);
        button.setBackground(capsule(white(0.08)));
        button.setPadding(dp(10), dp(10), dp(10), dp(10));
        button.setContentDescription(help);
        pressable(button);
        return button;
    }

    static ImageView logo(Context context, double size) {
        ImageView logo = new ImageView(context);
        try (java.io.InputStream icon = context.getAssets().open("Con.png")) {
            android.graphics.BitmapFactory.Options options = new android.graphics.BitmapFactory.Options();
            options.inSampleSize = size > 60 ? 2 : 4;
            logo.setImageBitmap(android.graphics.BitmapFactory.decodeStream(icon, null, options));
        } catch (Exception missing) {
            logo.setBackground(rounded(Color.rgb(31, 31, 31), size * 0.2));
        }
        logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        round(logo, size * 0.22);
        return logo;
    }

    static View toggle(Context context, boolean on) {
        View toggle = new View(context) {
            final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            @Override protected void onDraw(Canvas canvas) {
                float height = getHeight(), width = getWidth();
                paint.setColor(on ? ACCENT : white(0.18));
                canvas.drawRoundRect(new RectF(0, 0, width, height), height / 2, height / 2, paint);
                paint.setColor(Color.WHITE);
                float knob = dp(11), centre = on ? width - dp(3) - knob : dp(3) + knob;
                canvas.drawCircle(centre, height / 2, knob, paint);
            }
        };
        toggle.setLayoutParams(sized(48, 28));
        pressable(toggle);
        return toggle;
    }

    static final class Icon extends View {
        String name;
        int colour;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();

        Icon(Context context, String name, int colour) {
            super(context);
            this.name = name;
            this.colour = colour;
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }

        void set(String name, int colour) {
            if (name.equals(this.name) && colour == this.colour) return;
            this.name = name; this.colour = colour;
            invalidate();
        }

        @Override protected void onDraw(Canvas canvas) {
            float width = getWidth() - getPaddingLeft() - getPaddingRight(), height = getHeight() - getPaddingTop() - getPaddingBottom();
            float scale = Math.min(width, height) / 24f;
            canvas.save();
            canvas.translate(getPaddingLeft() + (width - 24 * scale) / 2, getPaddingTop() + (height - 24 * scale) / 2);
            canvas.scale(scale, scale);
            paint.setColor(colour);
            paint.setStrokeWidth(2f);
            paint.setStyle(Paint.Style.STROKE);
            path.reset();
            switch (name) {
                case "search":
                    canvas.drawCircle(10, 10, 6.5f, paint);
                    canvas.drawLine(15, 15, 20.5f, 20.5f, paint);
                    break;
                case "reload":
                    canvas.drawArc(new RectF(4, 4, 20, 20), -60, 300, false, paint);
                    path.moveTo(16.5f, 2.5f); path.lineTo(16.5f, 6.8f); path.lineTo(12.2f, 6.8f);
                    canvas.drawPath(path, paint);
                    break;
                case "gear": {
                    paint.setStrokeWidth(2.2f);
                    canvas.drawCircle(12, 12, 3.2f, paint);
                    canvas.drawCircle(12, 12, 7, paint);
                    for (int tooth = 0; tooth < 8; tooth++) {
                        double angle = tooth * Math.PI / 4;
                        canvas.drawLine((float) (12 + 7 * Math.cos(angle)), (float) (12 + 7 * Math.sin(angle)), (float) (12 + 10 * Math.cos(angle)), (float) (12 + 10 * Math.sin(angle)), paint);
                    }
                    break;
                }
                case "menu":
                    for (int line = 0; line < 3; line++) canvas.drawLine(4, 6 + line * 6, 20, 6 + line * 6, paint);
                    break;
                case "star": case "star.fill": {
                    for (int point = 0; point < 10; point++) {
                        double angle = -Math.PI / 2 + point * Math.PI / 5, radius = point % 2 == 0 ? 10 : 4.2;
                        float x = (float) (12 + radius * Math.cos(angle)), y = (float) (12.8 + radius * Math.sin(angle));
                        if (point == 0) path.moveTo(x, y); else path.lineTo(x, y);
                    }
                    path.close();
                    if (name.equals("star.fill")) paint.setStyle(Paint.Style.FILL_AND_STROKE);
                    paint.setStrokeWidth(1.6f);
                    canvas.drawPath(path, paint);
                    break;
                }
                case "play":
                    paint.setStyle(Paint.Style.FILL_AND_STROKE);
                    path.moveTo(7, 4); path.lineTo(20, 12); path.lineTo(7, 20); path.close();
                    canvas.drawPath(path, paint);
                    break;
                case "arrow.up.right":
                    canvas.drawLine(6, 18, 18, 6, paint);
                    path.moveTo(9, 6); path.lineTo(18, 6); path.lineTo(18, 15);
                    canvas.drawPath(path, paint);
                    break;
                case "chevron.left":
                    path.moveTo(15, 5); path.lineTo(8, 12); path.lineTo(15, 19);
                    canvas.drawPath(path, paint);
                    break;
                case "chevron.down":
                    paint.setStrokeWidth(2.6f);
                    path.moveTo(6, 9); path.lineTo(12, 15); path.lineTo(18, 9);
                    canvas.drawPath(path, paint);
                    break;
                case "xmark":
                    paint.setStrokeWidth(2.4f);
                    canvas.drawLine(6, 6, 18, 18, paint);
                    canvas.drawLine(18, 6, 6, 18, paint);
                    break;
                case "chart":
                    paint.setStyle(Paint.Style.FILL);
                    canvas.drawRoundRect(new RectF(4, 12, 8, 20), 1, 1, paint);
                    canvas.drawRoundRect(new RectF(10, 7, 14, 20), 1, 1, paint);
                    canvas.drawRoundRect(new RectF(16, 3, 20, 20), 1, 1, paint);
                    break;
                case "gamecontroller": {
                    paint.setStrokeWidth(1.8f);
                    path.moveTo(7, 7); path.lineTo(17, 7);
                    path.cubicTo(21, 7, 23, 13, 22.5f, 17); path.cubicTo(22, 20, 19, 20.5f, 17.5f, 18.5f);
                    path.lineTo(15.5f, 16); path.lineTo(8.5f, 16); path.lineTo(6.5f, 18.5f);
                    path.cubicTo(5, 20.5f, 2, 20, 1.5f, 17); path.cubicTo(1, 13, 3, 7, 7, 7); path.close();
                    canvas.drawPath(path, paint);
                    canvas.drawLine(5.5f, 11.5f, 9.5f, 11.5f, paint);
                    canvas.drawLine(7.5f, 9.5f, 7.5f, 13.5f, paint);
                    paint.setStyle(Paint.Style.FILL);
                    canvas.drawCircle(16, 10.5f, 1.1f, paint);
                    canvas.drawCircle(18.2f, 12.8f, 1.1f, paint);
                    break;
                }
                case "person": {
                    paint.setStrokeWidth(1.4f);
                    canvas.drawCircle(12, 12, 10, paint);
                    canvas.drawCircle(12, 9.5f, 3.5f, paint);
                    canvas.drawArc(new RectF(5.5f, 14, 18.5f, 26), 200, 140, false, paint);
                    break;
                }
                case "ellipsis":
                    paint.setStyle(Paint.Style.FILL);
                    for (int dot = 0; dot < 3; dot++) canvas.drawCircle(6 + dot * 6, 12, 1.6f, paint);
                    break;
                case "waves":
                    canvas.drawCircle(12, 12, 1.5f, paint);
                    canvas.drawArc(new RectF(7, 7, 17, 17), -45, 90, false, paint);
                    canvas.drawArc(new RectF(7, 7, 17, 17), 135, 90, false, paint);
                    canvas.drawArc(new RectF(3, 3, 21, 21), -45, 90, false, paint);
                    canvas.drawArc(new RectF(3, 3, 21, 21), 135, 90, false, paint);
                    break;
                case "clock":
                    canvas.drawCircle(12, 12, 9, paint);
                    path.moveTo(12, 7); path.lineTo(12, 12); path.lineTo(15.5f, 14);
                    canvas.drawPath(path, paint);
                    break;
                case "film":
                    canvas.drawRoundRect(new RectF(3, 4, 21, 20), 2.5f, 2.5f, paint);
                    canvas.drawLine(7.5f, 4, 7.5f, 20, paint);
                    canvas.drawLine(16.5f, 4, 16.5f, 20, paint);
                    canvas.drawLine(3, 12, 7.5f, 12, paint);
                    canvas.drawLine(16.5f, 12, 21, 12, paint);
                    break;
                case "wifi":
                    for (float radius : new float[] { 4.5f, 9, 13.5f }) canvas.drawArc(new RectF(12 - radius, 20 - radius, 12 + radius, 20 + radius), -135, 90, false, paint);
                    paint.setStyle(Paint.Style.FILL);
                    canvas.drawCircle(12, 20, 1.7f, paint);
                    break;
                case "arrow.down":
                    canvas.drawLine(12, 4, 12, 20, paint);
                    path.moveTo(6, 14); path.lineTo(12, 20); path.lineTo(18, 14);
                    canvas.drawPath(path, paint);
                    break;
                case "tv":
                    canvas.drawRoundRect(new RectF(2, 4, 22, 18), 2.5f, 2.5f, paint);
                    canvas.drawLine(8, 21, 16, 21, paint);
                    break;
                case "trophy":
                    path.moveTo(7, 4); path.lineTo(17, 4); path.lineTo(17, 9);
                    path.cubicTo(17, 12.5f, 14.8f, 15, 12, 15); path.cubicTo(9.2f, 15, 7, 12.5f, 7, 9); path.close();
                    path.moveTo(17, 6); path.cubicTo(21, 6, 21, 11, 16.5f, 11.5f);
                    path.moveTo(7, 6); path.cubicTo(3, 6, 3, 11, 7.5f, 11.5f);
                    canvas.drawPath(path, paint);
                    canvas.drawLine(12, 15, 12, 19, paint);
                    canvas.drawLine(8, 20, 16, 20, paint);
                    break;
                case "timer":
                    canvas.drawCircle(12, 13.5f, 8, paint);
                    canvas.drawLine(12, 13.5f, 12, 9, paint);
                    canvas.drawLine(9.5f, 3, 14.5f, 3, paint);
                    break;
                default: break;
            }
            canvas.restore();
        }
    }
}
