package app.con.check;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.view.MotionEvent;
import android.view.View;
import java.util.HashSet;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

final class TouchPadView extends View {
    private static final int LAYOUT = 0, DOWN = 1, MOVE = 2, UP = 3, CANCEL = 4;
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG), line = new Paint(Paint.ANTI_ALIAS_FLAG), words = new Paint(Paint.ANTI_ALIAS_FLAG);
    private JSONArray controls = new JSONArray();
    private Set<String> held = new HashSet<>();
    private float leftX, leftY, rightX, rightY;
    private boolean up, down, leftward, rightward;
    private float left, right;
    private final Runnable onScreen;

    TouchPadView(Context context, Runnable onScreen) {
        super(context);
        this.onScreen = onScreen;
        line.setStyle(Paint.Style.STROKE);
        line.setStrokeWidth(Look.dp(1.5));
        words.setTextAlign(Paint.Align.CENTER);
        words.setTypeface(Typeface.create(Typeface.DEFAULT, 600, false));
    }

    void edges(int leftPixels, int rightPixels) {
        left = leftPixels / Look.density; right = rightPixels / Look.density;
        layout();
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) { layout(); }

    private void layout() {
        if (getWidth() == 0) return;
        take(Shared.touch(LAYOUT, 0, 0, 0, getWidth() / Look.density, getHeight() / Look.density, left, right), false);
    }

    void letGo() {
        if (getWidth() > 0) take(Shared.touch(CANCEL, 0, 0, 0, getWidth() / Look.density, getHeight() / Look.density, left, right), false);
    }

    @Override public void setVisibility(int visibility) {
        if (visibility != VISIBLE && getVisibility() == VISIBLE) letGo();
        super.setVisibility(visibility);
    }

    private void take(String text, boolean touchDown) {
        try {
            JSONObject answer = new JSONObject(text);
            if (answer.has("controls")) controls = answer.getJSONArray("controls");
            Set<String> now = new HashSet<>();
            JSONArray pressed = answer.getJSONArray("held");
            for (int index = 0; index < pressed.length(); index++) now.add(pressed.getString(index));
            held = now;
            leftX = (float) answer.getJSONArray("left").getDouble(0); leftY = (float) answer.getJSONArray("left").getDouble(1);
            rightX = (float) answer.getJSONArray("right").getDouble(0); rightY = (float) answer.getJSONArray("right").getDouble(1);
            up = answer.getBoolean("up"); down = answer.getBoolean("down"); leftward = answer.getBoolean("leftward"); rightward = answer.getBoolean("rightward");
            invalidate();
            if (touchDown && !answer.optBoolean("hit", true)) onScreen.run();
        } catch (Exception broken) {
        }
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        float width = getWidth() / Look.density, height = getHeight() / Look.density;
        int index = event.getActionIndex();
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: case MotionEvent.ACTION_POINTER_DOWN:
                take(Shared.touch(DOWN, event.getPointerId(index), event.getX(index) / Look.density, event.getY(index) / Look.density, width, height, left, right), true);
                break;
            case MotionEvent.ACTION_MOVE:
                for (int one = 0; one < event.getPointerCount(); one++)
                    take(Shared.touch(MOVE, event.getPointerId(one), event.getX(one) / Look.density, event.getY(one) / Look.density, width, height, left, right), false);
                break;
            case MotionEvent.ACTION_UP: case MotionEvent.ACTION_POINTER_UP:
                take(Shared.touch(UP, event.getPointerId(index), 0, 0, width, height, left, right), false);
                break;
            case MotionEvent.ACTION_CANCEL:
                take(Shared.touch(CANCEL, 0, 0, 0, width, height, left, right), false);
                break;
            default: break;
        }
        return true;
    }

    private void glass(boolean pressed) {
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(pressed ? Look.white(0.42) : Color.argb(84, 0, 0, 0));
        line.setColor(Look.white(pressed ? 0.95 : 0.55));
        line.setStrokeWidth(Look.dp(1.5));
    }

    @Override protected void onDraw(Canvas canvas) {
        float scale = Look.density;
        for (int index = 0; index < controls.length(); index++) {
            JSONObject control = controls.optJSONObject(index);
            if (control == null) continue;
            String id = control.optString("id"), kind = control.optString("kind"), label = control.optString("label");
            float x = (float) control.optDouble("x") * scale, y = (float) control.optDouble("y") * scale, radius = (float) control.optDouble("radius") * scale;
            boolean pressed = held.contains(id);
            switch (kind) {
                case "stick": drawStick(canvas, id, x, y, radius, pressed); break;
                case "crosspiece": drawCrosspiece(canvas, x, y, radius); break;
                default:
                    if (id.equals("touchpad")) drawTouchpad(canvas, x, y, radius, pressed);
                    else if (kind.equals("trigger") || id.equals("l1") || id.equals("r1")) drawShoulder(canvas, x, y, radius, label, pressed);
                    else if (id.equals("share") || id.equals("options")) drawPill(canvas, x, y, label, pressed);
                    else drawButton(canvas, id, x, y, radius, label, pressed);
                    break;
            }
        }
    }

    private void drawStick(Canvas canvas, String id, float x, float y, float radius, boolean pressed) {
        glass(false);
        canvas.drawCircle(x, y, radius, fill);
        canvas.drawCircle(x, y, radius, line);
        line.setColor(Look.white(0.18));
        canvas.drawCircle(x, y, radius * 0.5f, line);
        float pushX = id.equals("leftStick") ? leftX : rightX, pushY = id.equals("leftStick") ? leftY : rightY;
        float knobX = x + pushX * radius * 0.55f, knobY = y - pushY * radius * 0.55f, knob = radius * 0.46f;
        fill.setColor(Color.argb(60, 0, 0, 0));
        canvas.drawCircle(knobX, knobY + Look.dp(2), knob, fill);
        fill.setColor(pressed ? Look.white(0.5) : Look.white(0.24));
        canvas.drawCircle(knobX, knobY, knob, fill);
        line.setColor(Look.white(pressed ? 1 : 0.75));
        line.setStrokeWidth(Look.dp(1.5));
        canvas.drawCircle(knobX, knobY, knob, line);
    }

    private void drawCrosspiece(Canvas canvas, float x, float y, float radius) {
        float half = radius * 0.34f, corner = Look.dp(7);
        Path across = new Path(), along = new Path(), shape = new Path();
        across.addRoundRect(new RectF(x - radius, y - half, x + radius, y + half), corner, corner, Path.Direction.CW);
        along.addRoundRect(new RectF(x - half, y - radius, x + half, y + radius), corner, corner, Path.Direction.CW);
        shape.op(across, along, Path.Op.UNION);
        glass(false);
        canvas.drawPath(shape, fill);
        boolean[] pressed = { up, rightward, down, leftward };
        for (int side = 0; side < 4; side++) {
            canvas.save();
            canvas.rotate(side * 90, x, y);
            if (pressed[side]) {
                canvas.save();
                canvas.clipPath(shape);
                fill.setColor(Look.white(0.42));
                canvas.drawRect(x - half, y - radius, x + half, y - half * 0.35f, fill);
                canvas.restore();
            }
            Path arrow = new Path();
            float tip = y - radius * 0.78f, base = y - radius * 0.52f, wide = half * 0.42f;
            arrow.moveTo(x, tip); arrow.lineTo(x + wide, base); arrow.lineTo(x - wide, base); arrow.close();
            fill.setColor(Look.white(pressed[side] ? 1 : 0.8));
            canvas.drawPath(arrow, fill);
            canvas.restore();
        }
        line.setColor(Look.white(0.55));
        line.setStrokeWidth(Look.dp(1.5));
        canvas.drawPath(shape, line);
    }

    private void drawButton(Canvas canvas, String id, float x, float y, float radius, String label, boolean pressed) {
        glass(pressed);
        canvas.drawCircle(x, y, radius, fill);
        canvas.drawCircle(x, y, radius, line);
        Paint mark = new Paint(Paint.ANTI_ALIAS_FLAG);
        mark.setStyle(Paint.Style.STROKE);
        mark.setStrokeWidth(Look.dp(2));
        mark.setStrokeJoin(Paint.Join.ROUND);
        mark.setStrokeCap(Paint.Cap.ROUND);
        mark.setColor(pressed ? Color.WHITE : Look.white(0.9));
        float size = radius * 0.42f;
        switch (id) {
            case "cross":
                canvas.drawLine(x - size * 0.85f, y - size * 0.85f, x + size * 0.85f, y + size * 0.85f, mark);
                canvas.drawLine(x + size * 0.85f, y - size * 0.85f, x - size * 0.85f, y + size * 0.85f, mark);
                break;
            case "moon": canvas.drawCircle(x, y, size, mark); break;
            case "box": canvas.drawRect(x - size * 0.85f, y - size * 0.85f, x + size * 0.85f, y + size * 0.85f, mark); break;
            case "pyramid": {
                Path triangle = new Path();
                triangle.moveTo(x, y - size); triangle.lineTo(x + size * 0.95f, y + size * 0.65f); triangle.lineTo(x - size * 0.95f, y + size * 0.65f); triangle.close();
                canvas.drawPath(triangle, mark);
                break;
            }
            default: drawLabel(canvas, label, x, y, radius * 0.62f, pressed); break;
        }
    }

    private void drawShoulder(Canvas canvas, float x, float y, float radius, String label, boolean pressed) {
        glass(pressed);
        RectF box = new RectF(x - radius * 1.05f, y - radius * 0.66f, x + radius * 1.05f, y + radius * 0.66f);
        canvas.drawRoundRect(box, radius * 0.66f, radius * 0.66f, fill);
        canvas.drawRoundRect(box, radius * 0.66f, radius * 0.66f, line);
        drawLabel(canvas, label, x, y, Look.dp(14), pressed);
    }

    private void drawPill(Canvas canvas, float x, float y, String label, boolean pressed) {
        words.setTextSize(Look.dp(10.5));
        float half = words.measureText(label) / 2 + Look.dp(9), tall = Look.dp(12);
        glass(pressed);
        RectF box = new RectF(x - half, y - tall, x + half, y + tall);
        canvas.drawRoundRect(box, tall, tall, fill);
        canvas.drawRoundRect(box, tall, tall, line);
        drawLabel(canvas, label, x, y, Look.dp(10.5), pressed);
    }

    private void drawTouchpad(Canvas canvas, float x, float y, float radius, boolean pressed) {
        glass(pressed);
        line.setColor(Look.white(pressed ? 0.9 : 0.35));
        RectF pad = new RectF(x - radius * 1.9f, y - radius * 0.62f, x + radius * 1.9f, y + radius * 0.62f);
        canvas.drawRoundRect(pad, Look.dp(10), Look.dp(10), fill);
        canvas.drawRoundRect(pad, Look.dp(10), Look.dp(10), line);
    }

    private void drawLabel(Canvas canvas, String label, float x, float y, float size, boolean pressed) {
        if (label.isEmpty()) return;
        words.setTextSize(size);
        words.setColor(pressed ? Color.WHITE : Look.white(0.9));
        canvas.drawText(label, x, y - (words.descent() + words.ascent()) / 2, words);
    }
}
