package de.al1c3.openflow;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.content.Context;
import android.os.Build;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Consumer;

/**
 * Android implementation of BLE communication with Flow 100 on top of {@link BluetoothGatt}.
 * It bridges Android's asynchronous {@link BluetoothGattCallback} model to the blocking
 * request/response API the protocol layer expects: each read/write/subscribe parks a
 * CompletableFuture keyed by characteristic UUID, and the matching GATT callback completes it.
 * Two hard Android constraints shaped this class:
 *  1. ONE GATT OPERATION AT A TIME. Android's GATT stack allows exactly one outstanding operation
 *     (read, write, or descriptor write). Firing a second before the first callback arrives makes the
 *     second silently fail. Because its methods BLOCK until completion, the caller
 *     naturally serialises operations -- as long as the caller never issues two concurrently.
 *  2. DO NOT BLOCK THE CALLBACK THREAD. GATT callbacks arrive on a binder thread; that same thread
 *     delivers the result that unblocks read()/write(). So read()/write()/subscribe() must be called
 *     from a dedicated WORKER thread, never from the UI thread (ANR) and never from inside a GATT
 *     callback (guaranteed deadlock). MainActivity hands {@code onReady} off to a background executor
 *     for exactly this reason.
 * Permissions: every gatt.* call needs BLUETOOTH_CONNECT (API 31+); MainActivity requests it before
 * connecting, so the calls here are annotated {@code @SuppressLint("MissingPermission")}.
 * Pre-/post-API-33: the value-carrying read/notify callbacks and the write/descriptor APIs changed
 * signature in Android 13 (Tiramisu). Both paths are implemented and routed to a single handler.
 */
@SuppressWarnings("NullableProblems")
@SuppressLint("MissingPermission")
public final class AndroidBleTransport {

    /** Client Characteristic Configuration Descriptor -- the on-air notification switch. */
    private static final UUID CCCD_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private static final long TIMEOUT_SECONDS = 10;

    private final Context context;
    private final BluetoothDevice device;
    private final Runnable onReady;       // run when services are discovered; may be null
    private final Runnable onDisconnect;  // run on disconnect; may be null

    private volatile BluetoothGatt gatt;

    private final Map<UUID, CompletableFuture<byte[]>> pendingReads = new ConcurrentHashMap<>();
    private final Map<UUID, CompletableFuture<Void>> pendingWrites = new ConcurrentHashMap<>();
    private final Map<UUID, CompletableFuture<Void>> pendingSubscribes = new ConcurrentHashMap<>();
    private final Map<UUID, Consumer<byte[]>> subscribers = new ConcurrentHashMap<>();

    /**
     * @param context      any Context (application context is fine)
     * @param device       the device to connect to (from a scan result)
     * @param onReady      run once services are discovered -- HAND THIS OFF TO A WORKER THREAD
     * @param onDisconnect run when the link drops; may be null
     */
    public AndroidBleTransport(Context context, BluetoothDevice device,
                               Runnable onReady, Runnable onDisconnect) {
        this.context = context.getApplicationContext();
        this.device = device;
        this.onReady = onReady;
        this.onDisconnect = onDisconnect;
    }

    /** Open the GATT connection. Direct connection (autoConnect=false), forced LE transport. */
    public void connect() {
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
    }

    /** Disconnect and release the GATT client. Safe to call more than once. */
    public void close() {
        BluetoothGatt g = gatt;
        if (g != null) {
            failAllPending(new IllegalStateException("transport closed"));
            g.disconnect();
            g.close();
            gatt = null;
        }
    }

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {

        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices();              // must finish before any read/write
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                failAllPending(new IllegalStateException("disconnected (status=" + status + ")"));
                if (onDisconnect != null) {
                    onDisconnect.run();
                }
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                if (onReady != null) {
                    onReady.run();                 // MainActivity posts this to a worker thread
                }
            } else {
                failAllPending(new IllegalStateException("service discovery failed: status=" + status));
            }
        }

        // ----- read result: pre-33 (value via getValue()) and 33+ (value as arg) -----
        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic ch, int status) {
            completeRead(ch.getUuid(), ch.getValue(), status);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic ch,
                                         byte[] value, int status) {
            completeRead(ch.getUuid(), value, status);
        }

        // ----- notification: pre-33 and 33+ overloads -----
        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic ch) {
            dispatchNotify(ch.getUuid(), ch.getValue());
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic ch,
                                            byte[] value) {
            dispatchNotify(ch.getUuid(), value);
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic ch, int status) {
            CompletableFuture<Void> f = pendingWrites.remove(ch.getUuid());
            if (f != null) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    f.complete(null);
                } else {
                    f.completeExceptionally(new IllegalStateException("write failed: status=" + status));
                }
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            CompletableFuture<Void> f = pendingSubscribes.remove(d.getCharacteristic().getUuid());
            if (f != null) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    f.complete(null);
                } else {
                    f.completeExceptionally(
                            new IllegalStateException("CCCD write failed: status=" + status));
                }
            }
        }
    };

    private void completeRead(UUID uuid, byte[] value, int status) {
        CompletableFuture<byte[]> f = pendingReads.remove(uuid);
        if (f == null) {
            return;
        }
        if (status == BluetoothGatt.GATT_SUCCESS) {
            f.complete(value != null ? value : new byte[0]);
        } else {
            f.completeExceptionally(new IllegalStateException("read failed: status=" + status));
        }
    }

    private void dispatchNotify(UUID uuid, byte[] value) {
        Consumer<byte[]> sub = subscribers.get(uuid);
        if (sub != null) {
            sub.accept(value != null ? value : new byte[0]);
        }
    }

    /** Blocking BLE transport operations (read/write/subscribe). */

    public byte[] read(UUID service, UUID characteristic) {
        BluetoothGattCharacteristic ch = require(service, characteristic);
        CompletableFuture<byte[]> future = new CompletableFuture<>();
        pendingReads.put(characteristic, future);
        if (!gatt.readCharacteristic(ch)) {
            pendingReads.remove(characteristic);
            throw new IllegalStateException("readCharacteristic was rejected for " + characteristic
                    + " (another GATT op in flight, or BLUETOOTH_CONNECT not granted)");
        }
        return await(future, characteristic, "read");
    }

    public void write(UUID service, UUID characteristic, byte[] value, boolean withResponse) {
        BluetoothGattCharacteristic ch = require(service, characteristic);
        int writeType = withResponse
                ? BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                : BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
        CompletableFuture<Void> future = new CompletableFuture<>();
        pendingWrites.put(characteristic, future);

        boolean queued;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            queued = gatt.writeCharacteristic(ch, value, writeType) == BluetoothStatusCodes.SUCCESS;
        } else {
            ch.setWriteType(writeType);
            ch.setValue(value);
            queued = gatt.writeCharacteristic(ch);
        }
        if (!queued) {
            pendingWrites.remove(characteristic);
            throw new IllegalStateException("writeCharacteristic was rejected for " + characteristic);
        }
        await(future, characteristic, "write");
    }

    public void subscribe(UUID service, UUID characteristic, Consumer<byte[]> listener) {
        BluetoothGattCharacteristic ch = require(service, characteristic);
        if (!gatt.setCharacteristicNotification(ch, true)) {
            throw new IllegalStateException("setCharacteristicNotification failed for " + characteristic);
        }
        BluetoothGattDescriptor cccd = ch.getDescriptor(CCCD_UUID);
        if (cccd == null) {
            throw new IllegalStateException("characteristic " + characteristic
                    + " has no CCCD (0x2902) -- it is not notifiable");
        }
        subscribers.put(characteristic, listener);

        CompletableFuture<Void> future = new CompletableFuture<>();
        pendingSubscribes.put(characteristic, future);
        byte[] enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;

        boolean queued;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            queued = gatt.writeDescriptor(cccd, enable) == BluetoothStatusCodes.SUCCESS;
        } else {
            cccd.setValue(enable);
            queued = gatt.writeDescriptor(cccd);
        }
        if (!queued) {
            subscribers.remove(characteristic);
            pendingSubscribes.remove(characteristic);
            throw new IllegalStateException("CCCD write was rejected for " + characteristic);
        }
        await(future, characteristic, "subscribe");
    }

    /**
     * Human-readable dump of every discovered service and characteristic (UUID + properties).
     * Call this on the worker thread after onReady to confirm PRIMARY_SERVICE against reality.
     */
    public String describeGatt() {
        BluetoothGatt g = gatt;
        if (g == null) {
            return "(not connected)";
        }
        List<BluetoothGattService> services = g.getServices();
        if (services.isEmpty()) {
            return "(no services discovered yet)";
        }
        StringBuilder sb = new StringBuilder();
        for (BluetoothGattService svc : services) {
            sb.append("service ").append(svc.getUuid()).append('\n');
            for (BluetoothGattCharacteristic ch : svc.getCharacteristics()) {
                sb.append("    char ").append(ch.getUuid())
                  .append("  [").append(properties(ch.getProperties())).append("]\n");
            }
        }
        return sb.toString();
    }

    @SuppressWarnings("SizeReplaceableByIsEmpty")
    private static String properties(int p) {
        StringBuilder sb = new StringBuilder();
        if ((p & BluetoothGattCharacteristic.PROPERTY_READ) != 0) sb.append("R");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) sb.append("W");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) sb.append("w");
        if ((p & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) sb.append("N");
        if ((p & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) sb.append("I");
        return sb.length() == 0 ? "-" : sb.toString();
    }

    private BluetoothGattCharacteristic require(UUID service, UUID characteristic) {
        BluetoothGatt g = gatt;
        if (g == null) {
            throw new IllegalStateException("not connected");
        }
        BluetoothGattService svc = g.getService(service);
        if (svc == null) {
            throw new IllegalStateException("service " + service + " not found -- check PRIMARY_SERVICE "
                    + "against the discovered-services dump");
        }
        BluetoothGattCharacteristic ch = svc.getCharacteristic(characteristic);
        if (ch == null) {
            throw new IllegalStateException("characteristic " + characteristic
                    + " not found in service " + service);
        }
        return ch;
    }

    private void failAllPending(Throwable cause) {
        for (CompletableFuture<byte[]> f : pendingReads.values()) f.completeExceptionally(cause);
        for (CompletableFuture<Void> f : pendingWrites.values()) f.completeExceptionally(cause);
        for (CompletableFuture<Void> f : pendingSubscribes.values()) f.completeExceptionally(cause);
        pendingReads.clear();
        pendingWrites.clear();
        pendingSubscribes.clear();
    }

    private <T> T await(CompletableFuture<T> future, UUID characteristic, String op) {
        try {
            return future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            pendingReads.remove(characteristic);
            pendingWrites.remove(characteristic);
            pendingSubscribes.remove(characteristic);
            throw new IllegalStateException("Timed out waiting for " + op + " on " + characteristic, e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted during " + op + " on " + characteristic, e);
        } catch (ExecutionException e) {
            throw new IllegalStateException("Error during " + op + " on " + characteristic, e.getCause());
        }
    }
}
