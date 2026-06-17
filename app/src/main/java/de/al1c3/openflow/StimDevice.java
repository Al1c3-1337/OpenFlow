package de.al1c3.openflow;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.function.Consumer;

/**
 * High-level driver for the stimulation device: pure protocol logic.
 * Endianness: the companion app uses .NET BitConverter on a little-endian host, and the firmware
 * target (Nordic / ARM Cortex-M) is little-endian, so every multibyte scalar here is LITTLE_ENDIAN.
 * Telemetry decode types: the on-wire types for the read-only telemetry characteristics (resistance,
 * currents, battery, error) were NOT documented. They are decoded here as the most plausible type and
 * each such assumption is marked. Confirm against the real values printed by Main and adjust if wrong.
 * Safety: several methods write current setpoints, status transitions, or interlock settings. Those
 * values are passed straight through to firmware that drives current through a person; nothing here
 * clamps them. Validate against the device's real limits before writing.
 */
@SuppressWarnings("unused")
public final class StimDevice {

    private final AndroidBleTransport ble;

    public StimDevice(AndroidBleTransport ble) {
        this.ble = ble;
    }

    /** Battery level. ASSUMPTION: single unsigned byte, 0..100 (%). */
    public int batteryLevel() {
        byte[] v = ble.read(StimUuids.PRIMARY_SERVICE, StimUuids.BATTERY_LEVEL);
        return v.length > 0 ? (v[0] & 0xFF) : -1;
    }

    /** Measured electrode resistance. ASSUMPTION: little-endian float32 (ohms). */
    public float resistance() {
        return readFloat(StimUuids.RESISTANCE);
    }

    /** Current actually delivered, as measured by the device. ASSUMPTION: little-endian float32 (mA). */
    public float measuredCurrent() {
        return readFloat(StimUuids.MEASURED_CURRENT);
    }

    /** Current setpoint as reported by the device. ASSUMPTION: little-endian float32 (mA). */
    public float targetCurrent() {
        return readFloat(StimUuids.TARGET_CURRENT);
    }

    /** Current stimulation status. */
    public StimulationStatus stimulationStatus() {
        byte[] v = ble.read(StimUuids.PRIMARY_SERVICE, StimUuids.STIMULATION_STATUS);
        return v.length > 0 ? StimulationStatus.fromCode(v[0]) : StimulationStatus.Unknown;
    }

    /** Last error code. ASSUMPTION: single unsigned byte. */
    public int errorCode() {
        byte[] v = ble.read(StimUuids.PRIMARY_SERVICE, StimUuids.ERROR_CODE);
        return v.length > 0 ? (v[0] & 0xFF) : -1;
    }

    /**
     * Write a setting. Wire format: [ordinal][float32 little-endian] -- identical to the companion app.
     * (The app's WriteSetting returned a bool from an inner scope that could never be read; this just
     * blocks until writing is acknowledged or throws.)
     */
    public void writeSetting(Setting setting, float value) {
        byte[] payload = new byte[5];
        payload[0] = setting.code();
        putFloatLE(payload, 1, value);
        ble.write(StimUuids.PRIMARY_SERVICE, StimUuids.SETTINGS, payload, true);
    }

    /**
     * Read a setting back.
     * INFERRED PROTOCOL -- verify against the real device. The companion app only ever WRITES the
     * Settings characteristic; the read path is not shown (its getSetting stub was broken -- it built a
     * zero-filled array of length=ordinal and passed it to a write call). Best guess implemented here:
     * write the 1-byte selector (the ordinal) to select the setting, then read the characteristic. The
     * device is assumed to answer with either [ordinal][float32 LE] (5 bytes) or [float32 LE] (4 bytes).
     * If it instead answers via notification, or uses a different selector mechanism, change this.
     */
    public float getSetting(Setting setting) {
        ble.write(StimUuids.PRIMARY_SERVICE, StimUuids.SETTINGS, new byte[]{ setting.code() }, true);
        byte[] v = ble.read(StimUuids.PRIMARY_SERVICE, StimUuids.SETTINGS);
        if (v.length >= 5) {
            return getFloatLE(v, 1);
        } else if (v.length == 4) {
            return getFloatLE(v, 0);
        }
        throw new IllegalStateException("Unexpected setting read length: " + v.length);
    }

    /** Convenience: set the target current (mA) via the Settings characteristic. */
    public void setTargetCurrent(float milliAmps) {
        writeSetting(Setting.TargetCurrent, milliAmps);
    }

    /**
     * Write the stimulation status (single status-code byte). The app's stub passed the enum object
     * straight to the write call, which does not compile; the wire value is the one status byte.
     */
    public void setStimulationStatus(StimulationStatus status) {
        ble.write(StimUuids.PRIMARY_SERVICE, StimUuids.STIMULATION_STATUS,
                new byte[]{ status.code() }, true);
    }

    /**
     * Play a tone. Wire format from the companion app: [pitch_lo, pitch_hi, duration_lo, duration_hi],
     * i.e. two little-endian int16 values, pitch first.
     */
    public void playSound(short pitch, short duration) {
        byte[] value = new byte[4];
        value[0] = (byte) (pitch & 0xFF);
        value[1] = (byte) ((pitch >> 8) & 0xFF);
        value[2] = (byte) (duration & 0xFF);
        value[3] = (byte) ((duration >> 8) & 0xFF);
        ble.write(StimUuids.PRIMARY_SERVICE, StimUuids.SOUND, value, true);
    }

    /** Subscribe to measured-current notifications (decoded as little-endian float32). */
    public void onMeasuredCurrent(Consumer<Float> listener) {
        ble.subscribe(StimUuids.PRIMARY_SERVICE, StimUuids.MEASURED_CURRENT,
                bytes -> listener.accept(getFloatLE(bytes, 0)));
    }

    /** Subscribe to status-change notifications. */
    public void onStatusChange(Consumer<StimulationStatus> listener) {
        ble.subscribe(StimUuids.PRIMARY_SERVICE, StimUuids.STIMULATION_STATUS,
                bytes -> listener.accept(bytes.length > 0
                        ? StimulationStatus.fromCode(bytes[0]) : StimulationStatus.Unknown));
    }

    /** Encoding/decoding helpers for protocol payloads. */

    private String readString(UUID characteristic) {
        byte[] v = ble.read(StimUuids.PRIMARY_SERVICE, characteristic);
        return new String(v, StandardCharsets.UTF_8).trim();
    }

    private float readFloat(UUID characteristic) {
        return getFloatLE(ble.read(StimUuids.PRIMARY_SERVICE, characteristic), 0);
    }

    @SuppressWarnings("SameParameterValue")
    private static void putFloatLE(byte[] dst, int offset, float value) {
        ByteBuffer.wrap(dst, offset, 4).order(ByteOrder.LITTLE_ENDIAN).putFloat(value);
    }

    private static float getFloatLE(byte[] src, int offset) {
        if (src == null || src.length < offset + 4) {
            throw new IllegalStateException("Expected >= 4 bytes for a float at offset " + offset
                    + " but got " + (src == null ? 0 : src.length));
        }
        return ByteBuffer.wrap(src, offset, 4).order(ByteOrder.LITTLE_ENDIAN).getFloat();
    }
}