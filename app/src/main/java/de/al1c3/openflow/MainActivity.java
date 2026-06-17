package de.al1c3.openflow;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.os.ParcelUuid;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ListView;
import android.widget.Spinner;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import no.nordicsemi.android.dfu.DfuProgressListener;
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter;
import no.nordicsemi.android.dfu.DfuServiceInitiator;
import no.nordicsemi.android.dfu.DfuServiceListenerHelper;

/**
 * Research front-end for the tDCS headset.
 * Flow: scan -> tap a device -> read-only inventory + GATT dump -> apply the original app's startup
 * default settings -> live status monitoring with guarded stimulation controls. Firmware update over
 * Nordic Secure DFU is wired (Select firmware -> Flash); the bootloader can also be entered manually.
 * Safety model (deliberately a subset of what the protocol exposes):
 *   - TargetCurrent and MaxStimulationTime are fixed in code (constants below), never in the UI.
 *   - The dangerous interlock settings (SkipElectrodeDetection, compliance/fault voltage limits, ...)
 *     are NOT exposed as controls. They are only written, with safe values, in the defaults block.
 *   - Stimulation transitions are guarded: RampUp is only allowed once the device reports UserDetected
 *     (no ramp-up before the user/electrodes are detected).
 *   - A dedicated RAMP DOWN button is always available as the stop sequence.
 *   - While stimulation is active the app arms a gentle auto ramp-down at AUTO_RAMPDOWN_MS, before the
 *     device's MaxStimulationTime cap, so the device never falls back to the abrupt QuickRampDown.
 * Threading: AndroidBleTransport's read/write block, so every device call runs on {@code worker}.
 * GATT callbacks (onReady, notifications) arrive on a binder thread and only hand off to that worker;
 * UI updates are posted back with runOnUiThread.
 */
@SuppressWarnings("NullableProblems")
public final class MainActivity extends Activity {

    private static final int REQ_PERMISSIONS = 1;
    private static final int REQ_PICK_FIRMWARE = 2;
    private static final int REQ_POST_NOTIFICATIONS = 3;
    private static final long SCAN_DURATION_MS = 12_000;
    private static final long STATUS_POLL_MS = 2_000;

    // ---- Fixed stimulation parameters (in code only; not exposed to the UI) ----
    private static final float TARGET_CURRENT_A = 0.002f;   // 2 mA setpoint
    private static final float RAMP_UP_TIME_S   = 120f;     // GetRampUpTime() (confirmed)
    private static final float MAX_STIM_TIME_S  = 1900f;    // device hard cap (written to MaxStimulationTime)
    // Gentle auto ramp-down well before the 1900 s cap, so the device never triggers QuickRampDown.
    private static final long AUTO_RAMPDOWN_MS  = 1_800_000; // 1800 s

    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private boolean scanning;
    private boolean dfuScanMode;   // true = scanning for a device already in DFU/bootloader mode

    private final List<BluetoothDevice> devices = new ArrayList<>();
    private ArrayAdapter<String> listAdapter;
    private TextView logView;
    private Button scanButton;
    private Button scanDfuButton;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "openflow-worker");
        t.setDaemon(true);
        return t;
    });

    private AndroidBleTransport transport;
    private volatile boolean ready;                                  // services discovered + initialised

    // Firmware update (DFU) state.
    private Button flashButton;
    private Uri firmwareUri;
    private String selectedAddress;
    private String selectedName;

    // Stimulation control views.
    private TextView statusLabel;
    private TextView telemetryView;
    private Spinner statusSpinner;
    private Button applyTransitionButton;
    private Button rampDownButton;
    private Button refreshStatusButton;
    private Button applyDefaultsButton;
    private Button beepButton;
    private Button melodyButton;

    // Live status + auto ramp-down state (touched on the main thread).
    private volatile StimulationStatus currentStatus = StimulationStatus.Unknown;
    private boolean polling;
    private boolean autoRampScheduled;
    private long autoRampDeadlineElapsedMs = -1L;
    private String latestTelemetryBody = "(not connected)";

    // Statuses offered in the transition dropdown (the user-commandable subset). The device drives the
    // detection/hold/diagnostic states itself. transitionAllowed() enforces which are valid right now.
    private static final StimulationStatus[] COMMANDABLE = {
            StimulationStatus.Idle,
            StimulationStatus.SelfDiagnostic,
            StimulationStatus.RampUp,
            StimulationStatus.RampDown,
    };

    private static final int[][] MELODY = {
            {392, 312}, {440, 312}, {466, 1875}, {392, 312}, {440, 312}, {466, 1562},
            {440, 312}, {392, 312}, {294, 312}, {349, 1250}, {392, 1250},
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        scanButton = findViewById(R.id.scan_button);
        scanDfuButton = findViewById(R.id.scan_dfu_button);
        logView = findViewById(R.id.log_view);
        ListView deviceList = findViewById(R.id.device_list);

        listAdapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1);
        deviceList.setAdapter(listAdapter);
        deviceList.setOnItemClickListener((parent, view, position, id) -> {
            stopScan();
            BluetoothDevice d = devices.get(position);
            if (dfuScanMode) {
                selectDfuTarget(d);   // device already in bootloader mode -> flash directly
            } else {
                connectTo(d);
            }
        });
        scanButton.setOnClickListener(v -> onScanClicked());
        scanDfuButton.setOnClickListener(v -> onScanDfuClicked());

        // ---- Firmware update (DFU) wiring ----
        Button selectFirmwareButton = findViewById(R.id.select_firmware_button);
        flashButton = findViewById(R.id.flash_button);
        flashButton.setEnabled(false);
        selectFirmwareButton.setOnClickListener(v -> pickFirmware());
        flashButton.setOnClickListener(v -> confirmAndFlash());
        DfuServiceInitiator.createDfuNotificationChannel(this);
        DfuServiceListenerHelper.registerProgressListener(this, dfuProgressListener);

        // ---- Stimulation control wiring ----
        statusLabel = findViewById(R.id.status_label);
        telemetryView = findViewById(R.id.telemetry_view);
        refreshStatusButton = findViewById(R.id.refresh_status_button);
        statusSpinner = findViewById(R.id.status_spinner);
        applyTransitionButton = findViewById(R.id.apply_transition_button);
        rampDownButton = findViewById(R.id.ramp_down_button);
        applyDefaultsButton = findViewById(R.id.apply_defaults_button);
        beepButton = findViewById(R.id.beep_button);
        melodyButton = findViewById(R.id.melody_button);

        ArrayAdapter<StimulationStatus> statusAdapter = new ArrayAdapter<>(
                this, android.R.layout.simple_spinner_item, COMMANDABLE);
        statusAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        statusSpinner.setAdapter(statusAdapter);

        refreshStatusButton.setOnClickListener(v -> refreshNow());
        applyTransitionButton.setOnClickListener(v -> applySelectedTransition());
        rampDownButton.setOnClickListener(v -> rampDownStop());
        applyDefaultsButton.setOnClickListener(v -> applyDefaultsManually());
        beepButton.setOnClickListener(v -> beep());
        melodyButton.setOnClickListener(v -> playMelody());

        refreshControls();

        BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = bm != null ? bm.getAdapter() : null;
        if (adapter == null) {
            log("This device has no Bluetooth adapter.");
            scanButton.setEnabled(false);
            scanDfuButton.setEnabled(false);
        }
    }

    /** Permission helpers and request handling. */

    private String[] requiredPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) { // API 31+
            return new String[]{
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
            };
        }
        return new String[]{ Manifest.permission.ACCESS_FINE_LOCATION }; // API <= 30
    }

    private boolean missesPermissions() {
        for (String p : requiredPermissions()) {
            if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
                return true;
            }
        }
        return false;
    }

    private void onScanClicked() {
        if (scanning) {
            stopScan();
            return;
        }
        dfuScanMode = false;
        if (missesPermissions()) {
            requestPermissions(requiredPermissions(), REQ_PERMISSIONS);
            return;
        }
        startScan();
    }

    /** Scan for a device already in DFU/bootloader mode (advertising the Secure DFU service). */
    private void onScanDfuClicked() {
        if (scanning) {
            stopScan();
            return;
        }
        dfuScanMode = true;
        if (missesPermissions()) {
            requestPermissions(requiredPermissions(), REQ_PERMISSIONS);
            return;
        }
        startScan();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != REQ_PERMISSIONS) {
            return;
        }
        boolean granted = results.length > 0;
        for (int r : results) {
            granted &= (r == PackageManager.PERMISSION_GRANTED);
        }
        if (granted) {
            startScan();
        } else {
            log("Permissions denied -- cannot scan without them.");
        }
    }

    /** BLE scan lifecycle and callbacks. */

    @SuppressLint("MissingPermission")
    private void startScan() {
        if (adapter == null || !adapter.isEnabled()) {
            log("Bluetooth is off -- enable it and try again.");
            return;
        }
        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            log("BLE scanner unavailable.");
            return;
        }

        devices.clear();
        listAdapter.clear();
        scanning = true;

        UUID filterService;
        if (dfuScanMode) {
            filterService = StimUuids.DFU_SERVICE;
            scanDfuButton.setText(R.string.stop);
            log("Scanning for DFU targets (bootloader mode) ...");
        } else {
            filterService = StimUuids.PRIMARY_SERVICE;
            scanButton.setText(R.string.stop_scan);
            log("Scanning " + (SCAN_DURATION_MS / 1000) + "s ...");
        }

        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build();

        // Filter discovery to the relevant service. NOTE: this only matches if the device ADVERTISES
        // the UUID. A stuck/recovery bootloader usually advertises 0xFE59; if the list stays empty
        // (app-mode or DFU), use the commented unfiltered line below.
        List<ScanFilter> filters = java.util.Collections.singletonList(
                new ScanFilter.Builder()
                        .setServiceUuid(new ParcelUuid(filterService))
                        .build());
        scanner.startScan(filters, settings, scanCallback);
        // scanner.startScan(null, settings, scanCallback); // unfiltered fallback

        mainHandler.postDelayed(this::stopScan, SCAN_DURATION_MS);
    }

    @SuppressLint("MissingPermission")
    private void stopScan() {
        if (!scanning) {
            return;
        }
        scanning = false;
        scanButton.setText(R.string.scan);
        scanDfuButton.setText(R.string.scan_dfu_target);
        mainHandler.removeCallbacks(this::stopScan);
        if (scanner != null) {
            scanner.stopScan(scanCallback);
        }
        log("Scan stopped (" + devices.size() + " device(s)).");
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        @SuppressLint("MissingPermission")
        public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice d = result.getDevice();
            String address = d.getAddress();
            for (BluetoothDevice existing : devices) {
                if (existing.getAddress().equals(address)) {
                    return;
                }
            }
            devices.add(d);
            String name = d.getName();
            listAdapter.add((name == null ? "(no name)" : name) + "  —  " + address);
            listAdapter.notifyDataSetChanged();
        }

        @Override
        public void onScanFailed(int errorCode) {
            scanning = false;
            scanButton.setText(R.string.scan);
            scanDfuButton.setText(R.string.scan_dfu_target);
            log("Scan failed: error " + errorCode);
        }
    };

    /** Device connection and ready/disconnect handling. */

    @SuppressLint("MissingPermission")
    private void connectTo(BluetoothDevice device) {
        log("Connecting to " + safeName(device) + " ...");
        selectedAddress = device.getAddress();
        selectedName = device.getName();
        ready = false;
        transport = new AndroidBleTransport(
                this,
                device,
                () -> worker.execute(this::onDeviceReady), // onReady -> worker thread
                this::onLinkDropped);                      // onDisconnect (binder thread)
        transport.connect();
    }

    /**
     * Select a device that is already in DFU/bootloader mode (found via "Scan DFU target"). No GATT
     * inventory or stimulation here -- a bootloader-mode device only exposes the DFU service. The DFU
     * library detects it is already in bootloader mode and flashes directly (no buttonless jump).
     */
    @SuppressLint("MissingPermission")
    private void selectDfuTarget(BluetoothDevice device) {
        if (transport != null) {
            transport.close();
            transport = null;
        }
        ready = false;
        stopStatusPoll();
        cancelAutoRampDown();
        refreshControls();

        selectedAddress = device.getAddress();
        selectedName = device.getName();
        log("DFU target selected: " + safeName(device) + " (bootloader mode).");
        log(firmwareUri == null ? "Pick a firmware .zip, then Flash." : "Ready to Flash.");
        if (firmwareUri != null) {
            flashButton.setEnabled(true);
        }
    }

    private void onLinkDropped() {
        ready = false;
        currentStatus = StimulationStatus.Unknown;
        runOnUiThread(() -> {
            log("Link dropped.");
            stopStatusPoll();
            cancelAutoRampDown();
            updateTelemetry("(disconnected)");
            refreshControls();
        });
    }

    /** Runs on {@code worker} once services are discovered. */
    private void onDeviceReady() {
        AndroidBleTransport t = transport;
        if (t == null) {
            return;
        }
        runInventory(t);
        applyDefaultSettings(t);
        ready = true;
        try {
            updateStatus(new StimDevice(t).stimulationStatus());
        } catch (Exception e) {
            ui("status read failed: " + rootMessage(e));
        }
        runOnUiThread(() -> {
            refreshControls();
            startStatusPoll();
        });
    }

    /** Runs on {@code worker}. Reads only. */
    private void runInventory(AndroidBleTransport t) {
        ui("Connected. Discovered GATT table:");
        ui(t.describeGatt());

        StimDevice dev = new StimDevice(t);
        ui("--- device info ---");
        probe("battery %", dev::batteryLevel);
        probe("error code", dev::errorCode);
        ui("--- status + currents now update live every " + (STATUS_POLL_MS / 1000) + "s ---");
    }

    private interface Probe {
        Object get() throws Exception;
    }

    private void probe(String label, Probe p) {
        try {
            ui(label + " = " + p.get());
        } catch (Exception e) {
            ui(label + " = ERROR: " + rootMessage(e));
        }
    }

    private static String describeBytes(byte[] v) {
        if (v == null || v.length == 0) {
            return "(empty)";
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : v) {
            hex.append(String.format("%02X ", b));
        }
        String s = v.length + " bytes [" + hex.toString().trim() + "]";
        if (v.length == 2) {
            int u16 = (v[0] & 0xFF) | ((v[1] & 0xFF) << 8);
            s += "  uint16(LE)=" + u16;
        } else if (v.length == 4) {
            int i32 = (v[0] & 0xFF) | ((v[1] & 0xFF) << 8) | ((v[2] & 0xFF) << 16) | ((v[3] & 0xFF) << 24);
            s += "  int32(LE)=" + i32 + "  float(LE)=" + Float.intBitsToFloat(i32);
        }
        return s;
    }

    /** Runs on {@code worker}. Writes the startup defaults. */
    private void applyDefaultSettings(AndroidBleTransport t) {
        StimDevice dev = new StimDevice(t);
        ui("Applying default settings (original app startup set)...");
        writeDefault(dev, Setting.CurrentRampUpRate, TARGET_CURRENT_A / RAMP_UP_TIME_S);
        writeDefault(dev, Setting.CurrentRampDownRate, TARGET_CURRENT_A / 15f);
        writeDefault(dev, Setting.CurrentQuickRampDown, TARGET_CURRENT_A / 6f);
        writeDefault(dev, Setting.UserDetectedThresholdResistance, 4_000_000f);
        writeDefault(dev, Setting.SkipElectrodeDetection, 0f);
        writeDefault(dev, Setting.BatteryLowerProtectionLimit, 0.25f);
        writeDefault(dev, Setting.DisableTickets, 1f);
        writeDefault(dev, Setting.MinTicketTime, 1f);
        writeDefault(dev, Setting.MaxStimulationTime, MAX_STIM_TIME_S);
        writeDefault(dev, Setting.TargetCurrent, TARGET_CURRENT_A);
        ui("Default settings applied.");
    }

    private void writeDefault(StimDevice dev, Setting s, float v) {
        try {
            dev.writeSetting(s, v);
        } catch (Exception e) {
            ui("  " + s + " write failed: " + rootMessage(e));
        }
    }

    private void applyDefaultsManually() {
        final AndroidBleTransport t = transport;
        if (!ready || t == null) {
            log("Connect to a device first.");
            return;
        }
        worker.execute(() -> applyDefaultSettings(t));
    }

    /** Refresh button: force an immediate read of status + telemetry. */
    private void refreshNow() {
        if (!ready || transport == null) {
            log("Connect to a device first.");
            return;
        }
        pollOnce();
    }

    /**
     * Enqueue one read of status + live telemetry (resistance, target/measured current) on the worker.
     * Silent on failure -- used by both the Refresh button and the periodic poll.
     */
    private void pollOnce() {
        final AndroidBleTransport t = transport;
        if (!ready || t == null) {
            return;
        }
        worker.execute(() -> {
            try {
                updateStatus(new StimDevice(t).stimulationStatus());
            } catch (Exception e) {
                // transient read failure; try again next tick
            }
            // Numeric telemetry. On-wire format is still unverified, so show raw bytes + candidate
            // decodes; once the real type/scaling is confirmed this becomes clean units.
            String tele = "resistance: " + safeDescribe(t, StimUuids.RESISTANCE) + "\n"
                    + "target current: " + safeDescribe(t, StimUuids.TARGET_CURRENT) + "\n"
                    + "measured curr.: " + safeDescribe(t, StimUuids.MEASURED_CURRENT);
            updateTelemetry(tele);
        });
    }

    private static String safeDescribe(AndroidBleTransport t, UUID uuid) {
        try {
            return describeBytes(t.read(StimUuids.PRIMARY_SERVICE, uuid));
        } catch (Exception e) {
            return "err: " + rootMessage(e);
        }
    }

    private void updateTelemetry(String text) {
        runOnUiThread(() -> {
            latestTelemetryBody = text;
            refreshTelemetryView();
        });
    }

    private void refreshTelemetryView() {
        if (telemetryView == null) {
            return;
        }
        String text = latestTelemetryBody;
        if (isStimulationActive(currentStatus) && autoRampScheduled && autoRampDeadlineElapsedMs > 0L) {
            long remainingMs = Math.max(0L, autoRampDeadlineElapsedMs - SystemClock.elapsedRealtime());
            long remainingSeconds = (remainingMs + 999L) / 1000L;
            text = "stim countdown: " + remainingSeconds + " s\n" + latestTelemetryBody;
        }
        telemetryView.setText(text);
    }

    private final Runnable countdownTicker = new Runnable() {
        @Override
        public void run() {
            if (!autoRampScheduled || !isStimulationActive(currentStatus)) {
                return;
            }
            refreshTelemetryView();
            mainHandler.postDelayed(this, 1000L);
        }
    };

    private final Runnable statusPoll = new Runnable() {
        @Override
        public void run() {
            if (!polling) {
                return;
            }
            pollOnce();
            if (polling) {
                mainHandler.postDelayed(this, STATUS_POLL_MS);
            }
        }
    };

    private void startStatusPoll() {
        if (polling) {
            return;
        }
        polling = true;
        mainHandler.postDelayed(statusPoll, STATUS_POLL_MS);
    }

    private void stopStatusPoll() {
        polling = false;
        mainHandler.removeCallbacks(statusPoll);
    }

    /** May be called from any thread; marshals to the UI thread. */
    private void updateStatus(StimulationStatus s) {
        currentStatus = s;
        runOnUiThread(() -> {
            if (statusLabel != null) {
                statusLabel.setText(getString(R.string.status2, s));
            }
            handleAutoRampDown(s);
            refreshControls();
        });
    }

    private void applySelectedTransition() {
        if (!ready) {
            log("Connect to a device first.");
            return;
        }
        StimulationStatus target = (StimulationStatus) statusSpinner.getSelectedItem();
        StimulationStatus cur = currentStatus;
        if (!transitionAllowed(cur, target)) {
            log("Transition " + cur + " -> " + target + " not allowed.");
            return;
        }
        commandStatus(target);
    }

    /**
     * Which transitions the UI permits. Best-effort guard from the observed state machine
     * (Idle -> WaitForElectrodes -> ElectrodesDetected -> WaitForUser -> UserDetected -> RampUp ->
     * CurrentHold -> RampDown); confirm against the device. The key rule: no RampUp before UserDetected.
     */
    private boolean transitionAllowed(StimulationStatus cur, StimulationStatus target) {
        return switch (target) {
            case RampUp -> cur == StimulationStatus.UserDetected;
            case RampDown ->
                    cur == StimulationStatus.RampUp || cur == StimulationStatus.CurrentHold;
            case SelfDiagnostic -> cur == StimulationStatus.Idle;
            case Idle ->
                // allow returning to idle only when no current is flowing
                    cur != StimulationStatus.RampUp && cur != StimulationStatus.CurrentHold;
            default -> false;
        };
    }

    /** The stop sequence. Always available while connected; sends RampDown regardless of guard. */
    private void rampDownStop() {
        if (!ready) {
            log("Connect to a device first.");
            return;
        }
        cancelAutoRampDown();
        commandStatus(StimulationStatus.RampDown);
    }

    private void commandStatus(StimulationStatus target) {
        final AndroidBleTransport t = transport;
        if (t == null) {
            ui("not connected");
            return;
        }
        worker.execute(() -> {
            try {
                new StimDevice(t).setStimulationStatus(target);
                ui("status -> " + target);
                updateStatus(new StimDevice(t).stimulationStatus());
            } catch (Exception e) {
                ui("status write failed: " + rootMessage(e));
            }
        });
    }

    /** Auto ramp-down scheduling and cancellation before the device hard cap. */

    private final Runnable autoRampDownRunnable = () -> {
        autoRampScheduled = false;
        autoRampDeadlineElapsedMs = -1L;
        mainHandler.removeCallbacks(countdownTicker);
        refreshTelemetryView();
        log("Auto ramp-down (" + (AUTO_RAMPDOWN_MS / 1000) + "s) -> sending RampDown");
        commandStatus(StimulationStatus.RampDown);
    };

    /** Runs on the UI thread (from updateStatus). Arms/disarms the timer with the active state. */
    private void handleAutoRampDown(StimulationStatus s) {
        boolean active = isStimulationActive(s);
        if (active && !autoRampScheduled) {
            autoRampScheduled = true;
            autoRampDeadlineElapsedMs = SystemClock.elapsedRealtime() + AUTO_RAMPDOWN_MS;
            mainHandler.postDelayed(autoRampDownRunnable, AUTO_RAMPDOWN_MS);
            mainHandler.removeCallbacks(countdownTicker);
            mainHandler.post(countdownTicker);
            log("Auto ramp-down armed (" + (AUTO_RAMPDOWN_MS / 1000) + "s).");
        } else if (!active && autoRampScheduled) {
            cancelAutoRampDown();
        } else {
            refreshTelemetryView();
        }
    }

    private void cancelAutoRampDown() {
        autoRampScheduled = false;
        autoRampDeadlineElapsedMs = -1L;
        mainHandler.removeCallbacks(autoRampDownRunnable);
        mainHandler.removeCallbacks(countdownTicker);
        refreshTelemetryView();
    }

    private static boolean isStimulationActive(StimulationStatus status) {
        return status == StimulationStatus.RampUp || status == StimulationStatus.CurrentHold;
    }

    /** Device sound controls. */

    private void beep() {
        final AndroidBleTransport t = transport;
        if (!ready || t == null) {
            log("Connect to a device first.");
            return;
        }
        worker.execute(() -> {
            try {
                new StimDevice(t).playSound((short) 1000, (short) 150);
                ui("beep");
            } catch (Exception e) {
                ui("beep failed: " + rootMessage(e));
            }
        });
    }

    private void playMelody() {
        final AndroidBleTransport t = transport;
        if (!ready || t == null) {
            log("Connect to a device first.");
            return;
        }
        worker.execute(() -> {
            try {
                StimDevice dev = new StimDevice(t);
                for (int[] note : MELODY) {
                    dev.playSound((short) note[0], (short) note[1]);
                    Thread.sleep(note[1] + 60L); // let the note finish before the next
                }
                ui("melody done");
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            } catch (Exception e) {
                ui("melody failed: " + rootMessage(e));
            }
        });
    }

    /**
     * Firmware update (DFU) flow.
     * Nordic Android-DFU-Library (the library Laerdal.Dfu binds) verifies package signatures via
     * Secure DFU (service 0000fe59), so unsigned/tampered firmware is rejected. The package must be a
     * .zip built with nRF Util. The buttonless app-to-bootloader switch is handled by the library;
     * "Enter DFU bootloader" does it manually over GATT (writes 0x01 to the buttonless characteristic).
     */

    private final DfuProgressListener dfuProgressListener = new DfuProgressListenerAdapter() {
        @Override public void onDeviceConnecting(String addr) { ui("DFU: connecting..."); }
        @Override public void onDfuProcessStarting(String addr) { ui("DFU: starting..."); }
        @Override public void onEnablingDfuMode(String addr) { ui("DFU: switching to bootloader..."); }
        @Override public void onProgressChanged(String addr, int percent, float speed, float avgSpeed,
                                                int part, int total) {
            ui("DFU: " + percent + "%  (part " + part + "/" + total + ")");
        }
        @Override public void onDfuCompleted(String addr) { ui("DFU: completed."); }
        @Override public void onDfuAborted(String addr) { ui("DFU: aborted."); }
        @Override public void onError(String addr, int error, int errorType, String message) {
            ui("DFU: error " + error + " - " + message);
        }
    };

    private void pickFirmware() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        // DFU packages are .zip, but some providers report octet-stream, so accept all and let the
        // user pick the right file.
        intent.setType("*/*");
        startActivityForResult(intent, REQ_PICK_FIRMWARE);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_PICK_FIRMWARE && resultCode == RESULT_OK && data != null) {
            firmwareUri = data.getData();
            log("Firmware selected: " + firmwareUri);
            if (selectedAddress != null) {
                flashButton.setEnabled(true);
            } else {
                log("Pick a device from the list before flashing.");
            }
        }
    }

    private void confirmAndFlash() {
        if (selectedAddress == null) {
            log("Connect to (or select) a device first.");
            return;
        }
        if (firmwareUri == null) {
            log("Select a firmware .zip first.");
            return;
        }
        new android.app.AlertDialog.Builder(this)
                .setTitle("Flash firmware?")
                .setMessage("Upload the selected package to "
                        + (selectedName == null ? selectedAddress : selectedName)
                        + " and reboot it.\n\nSecure DFU will reject any package not signed with the "
                        + "vendor key.")
                .setPositiveButton("Flash", (d, w) -> startDfu())
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void startDfu() {
        // Stop our own activity and release the GATT link so the DFU library can own the connection.
        stopStatusPoll();
        cancelAutoRampDown();
        ready = false;
        if (transport != null) {
            transport.close();
            transport = null;
        }
        stopScan();
        refreshControls();

        // Android 13+: the progress notification needs POST_NOTIFICATIONS. The update still runs if
        // denied; only the notification is suppressed.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{ Manifest.permission.POST_NOTIFICATIONS },
                    REQ_POST_NOTIFICATIONS);
        }

        log("Starting DFU on " + selectedAddress + " ...");
        DfuServiceInitiator starter = new DfuServiceInitiator(selectedAddress)
                .setDeviceName(selectedName)
                .setKeepBond(false)
                .setForceDfu(false)
                // SDK-12 bootloader fixes (this device is SDK-12-era -- see the buttonless flag below):
                .setMtu(23)                                  // no higher-MTU support before SDK 15; keep 20-byte packets
                .setPacketsReceiptNotificationsEnabled(true) // flow control: SDK-12 flash is slow, prevents host overrun
                .setPacketsReceiptNotificationsValue(12)     // lower toward 1 if it still fails mid-transfer
                .setPrepareDataObjectDelay(400L)
                .setNumberOfRetries(3)
                // Required so the app-mode buttonless jump works (harmless when flashing a DFU target directly):
                .setUnsafeExperimentalButtonlessServiceInSecureDfuEnabled(true);
        starter.setZip(firmwareUri);
        starter.start(this, DfuService.class);
    }

    /** UI state/render helpers. */

    private void refreshControls() {
        boolean r = ready;
        setEnabled(statusSpinner, r);
        setEnabled(applyTransitionButton, r);
        setEnabled(rampDownButton, r);
        setEnabled(refreshStatusButton, r);
        setEnabled(applyDefaultsButton, r);
        setEnabled(beepButton, r);
        setEnabled(melodyButton, r);
    }

    private static void setEnabled(android.view.View v, boolean enabled) {
        if (v != null) {
            v.setEnabled(enabled);
        }
    }

    private void ui(String line) {
        runOnUiThread(() -> log(line));
    }

    private void log(String line) {
        logView.append(line + "\n");
        if (logView.getParent() instanceof android.widget.ScrollView sv) {
            sv.post(() -> sv.fullScroll(android.view.View.FOCUS_DOWN));
        }
    }

    @SuppressLint("MissingPermission")
    private String safeName(BluetoothDevice d) {
        String n = d.getName();
        return (n == null ? "(no name)" : n) + " " + d.getAddress();
    }

    private static String rootMessage(Throwable e) {
        Throwable c = e;
        while (c.getCause() != null && c.getCause() != c) {
            c = c.getCause();
        }
        String m = c.getMessage();
        return m != null ? m : c.getClass().getSimpleName();
    }

    @Override
    @SuppressLint("MissingPermission")
    protected void onDestroy() {
        super.onDestroy();
        stopScan();
        stopStatusPoll();
        cancelAutoRampDown();
        DfuServiceListenerHelper.unregisterProgressListener(this, dfuProgressListener);
        if (transport != null) {
            transport.close();
        }
        worker.shutdownNow();
    }
}

