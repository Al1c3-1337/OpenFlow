package de.al1c3.openflow;

import java.util.UUID;

/**
 * GATT UUIDs for the stimulation device.
 * The vendor characteristics all share the 128-bit base 4C5B-00xx-C40B-49EE-9427-6E7CC8C388F3.
 * The primary SERVICE UUID is 0x0001 in that base, confirmed against the device's discovered
 * services.
 */
@SuppressWarnings("unused")
public final class StimUuids {

    private StimUuids() {}

    // ---- Vendor service (confirmed against the device) ----
    public static final UUID PRIMARY_SERVICE   = UUID.fromString("4C5B0001-C40B-49EE-9427-6E7CC8C388F3");

    // ---- Vendor characteristics ----
    public static final UUID RESISTANCE         = UUID.fromString("4C5B0002-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID TARGET_CURRENT     = UUID.fromString("4C5B0003-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID MEASURED_CURRENT   = UUID.fromString("4C5B0004-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID STIMULATION_STATUS = UUID.fromString("4C5B0005-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID BATTERY_LEVEL      = UUID.fromString("4C5B0006-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID TICKET             = UUID.fromString("4C5B0007-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID ERROR_CODE         = UUID.fromString("4C5B0008-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID SOUND              = UUID.fromString("4C5B0009-C40B-49EE-9427-6E7CC8C388F3");
    public static final UUID SETTINGS           = UUID.fromString("4C5B000A-C40B-49EE-9427-6E7CC8C388F3");

    // ---- Nordic Secure DFU ----
    public static final UUID DFU_SERVICE        = UUID.fromString("0000fe59-0000-1000-8000-00805f9b34fb");
    public static final UUID BUTTONLESS_DFU     = UUID.fromString("8E400001-F315-4F60-9FB8-838830DAEA50");
}
