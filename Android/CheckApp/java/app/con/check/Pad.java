package app.con.check;

import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

final class Pad {
    private int keys, hat;
    private boolean leftPressed, rightPressed;
    private float l2, r2, leftX, leftY, rightX, rightY;
    private boolean held;

    private static int bit(int key) {
        switch (key) {
            case KeyEvent.KEYCODE_BUTTON_A: return 0;
            case KeyEvent.KEYCODE_BUTTON_B: return 1;
            case KeyEvent.KEYCODE_BUTTON_X: return 2;
            case KeyEvent.KEYCODE_BUTTON_Y: return 3;
            case KeyEvent.KEYCODE_BUTTON_L1: return 4;
            case KeyEvent.KEYCODE_BUTTON_R1: return 5;
            case KeyEvent.KEYCODE_BUTTON_THUMBL: return 6;
            case KeyEvent.KEYCODE_BUTTON_THUMBR: return 7;
            case KeyEvent.KEYCODE_BUTTON_START: return 8;
            case KeyEvent.KEYCODE_BUTTON_SELECT: return 9;
            case KeyEvent.KEYCODE_BUTTON_MODE: return 10;
            case KeyEvent.KEYCODE_DPAD_UP: return 12;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 13;
            case KeyEvent.KEYCODE_DPAD_LEFT: return 14;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 15;
            default: return -1;
        }
    }

    static boolean fromPad(int source) {
        return (source & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD || (source & InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK;
    }

    static boolean isPad(InputDevice device) {
        if (device == null || device.isVirtual()) return false;
        int sources = device.getSources();
        if ((sources & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD) return true;
        if ((sources & InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK) return false;
        boolean[] keys = device.hasKeys(KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_B);
        return keys[0] && keys[1];
    }

    static boolean connected() {
        for (int id : InputDevice.getDeviceIds()) {
            if (isPad(InputDevice.getDevice(id))) return true;
        }
        return false;
    }

    static java.util.List<String> names() {
        java.util.List<String> names = new java.util.ArrayList<>();
        for (int id : InputDevice.getDeviceIds()) {
            InputDevice device = InputDevice.getDevice(id);
            if (isPad(device)) names.add(device.getName());
        }
        return names;
    }

    boolean key(KeyEvent event) {
        if (!fromPad(event.getSource())) return false;
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        int key = event.getKeyCode(), bit = bit(key);
        if (key == KeyEvent.KEYCODE_BUTTON_L2) leftPressed = down;
        else if (key == KeyEvent.KEYCODE_BUTTON_R2) rightPressed = down;
        else if (bit < 0) return false;
        else if (down) keys |= 1 << bit;
        else keys &= ~(1 << bit);
        send();
        return true;
    }

    private static float axis(MotionEvent event, int axis) {
        float value = event.getAxisValue(axis);
        InputDevice.MotionRange range = event.getDevice() == null ? null : event.getDevice().getMotionRange(axis, event.getSource());
        return range != null && Math.abs(value) <= range.getFlat() ? 0 : value;
    }

    boolean motion(MotionEvent event) {
        if ((event.getSource() & InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK || event.getAction() != MotionEvent.ACTION_MOVE) return false;
        leftX = axis(event, MotionEvent.AXIS_X); leftY = -axis(event, MotionEvent.AXIS_Y);
        rightX = axis(event, MotionEvent.AXIS_Z); rightY = -axis(event, MotionEvent.AXIS_RZ);
        l2 = Math.max(axis(event, MotionEvent.AXIS_LTRIGGER), axis(event, MotionEvent.AXIS_BRAKE));
        r2 = Math.max(axis(event, MotionEvent.AXIS_RTRIGGER), axis(event, MotionEvent.AXIS_GAS));
        float across = event.getAxisValue(MotionEvent.AXIS_HAT_X), along = event.getAxisValue(MotionEvent.AXIS_HAT_Y);
        hat = (along < -0.5f ? 1 << 12 : 0) | (along > 0.5f ? 1 << 13 : 0) | (across < -0.5f ? 1 << 14 : 0) | (across > 0.5f ? 1 << 15 : 0);
        send();
        return true;
    }

    private void send() {
        held = true;
        Shared.pad(keys | hat, Math.max(l2, leftPressed ? 1 : 0), Math.max(r2, rightPressed ? 1 : 0), leftX, leftY, rightX, rightY);
    }

    void release() {
        keys = 0; hat = 0; leftPressed = false; rightPressed = false;
        l2 = 0; r2 = 0; leftX = 0; leftY = 0; rightX = 0; rightY = 0;
        if (held) Shared.padGone();
        held = false;
    }
}
