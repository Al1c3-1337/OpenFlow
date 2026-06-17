package de.al1c3.openflow;

import android.app.Activity;

import no.nordicsemi.android.dfu.DfuBaseService;

/**
 * The foreground service that runs the firmware update, required by Nordic's Android-DFU-Library.
 * The library does all the work; this subclass only points its progress notification back at
 * {@link MainActivity}. Registered in AndroidManifest.xml with foregroundServiceType="connectedDevice".
 */
public final class DfuService extends DfuBaseService {

    @Override
    protected Class<? extends Activity> getNotificationTarget() {
        // Tapping the DFU notification reopens the app.
        return MainActivity.class;
    }
}
